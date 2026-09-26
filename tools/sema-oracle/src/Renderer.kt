package klio.semaoracle

import org.jetbrains.kotlin.descriptors.ClassKind
import org.jetbrains.kotlin.fir.FirSession
import org.jetbrains.kotlin.fir.containingClassLookupTag
import org.jetbrains.kotlin.fir.declarations.FirDeclarationOrigin
import org.jetbrains.kotlin.fir.resolve.fullyExpandedType
import org.jetbrains.kotlin.fir.resolve.providers.symbolProvider
import org.jetbrains.kotlin.fir.resolve.toClassLikeSymbol
import org.jetbrains.kotlin.fir.scopes.impl.typeAliasConstructorInfo
import org.jetbrains.kotlin.fir.symbols.FirBasedSymbol
import org.jetbrains.kotlin.fir.symbols.impl.*
import org.jetbrains.kotlin.fir.types.*
import org.jetbrains.kotlin.fir.unwrapFakeOverrides
import org.jetbrains.kotlin.name.ClassId
import org.jetbrains.kotlin.name.FqName

/** Renders symbols and types into the oracle's text forms. */
class Renderer(private val session: FirSession, private val out: FileCollector) {

    /**
     * The resolved symbol as a target string. [receiverType] is the static type of the
     * dispatch receiver at the site; it names the owner when the declaration lives in a
     * JDK class that has no Kotlin name (java/lang/AbstractStringBuilder).
     */
    fun target(symbol: FirBasedSymbol<*>, receiverType: ConeKotlinType? = null): String? {
        val sym = unwrap(symbol)
        return when (sym) {
            is FirEnumEntrySymbol -> "enum:" + ownerPrefix(sym, null) + sym.name.asString()
            is FirBackingFieldSymbol -> "field:" + callableName(sym.propertySymbol, null)
            is FirValueParameterSymbol -> local(sym)
            is FirCallableSymbol<*> -> {
                if (sym.origin == FirDeclarationOrigin.SamConstructor) {
                    val iface = (sym.resolvedReturnType.fullyExpandedType(session).lowerBoundIfFlexible() as? ConeClassLikeType)
                    return "sam:" + (iface?.let { typeClass(it) } ?: sym.name.asString())
                }
                if (isTrueLocal(sym)) return local(sym)
                val receiver = sym.resolvedReceiverType?.let { erase(it) } ?: ""
                val params = (sym as? FirFunctionSymbol<*>)?.valueParameterSymbols?.joinToString(",") { p ->
                    if (p.isVararg) erase(p.resolvedReturnType.varargElementType()) + "..." else erase(p.resolvedReturnType)
                } ?: ""
                callableName(sym, receiverType) + "|" + receiver + "|" + params
            }
            is FirClassLikeSymbol<*> -> "object:" + classSymbol(sym)
            else -> null
        }
    }

    private fun unwrap(symbol: FirBasedSymbol<*>): FirBasedSymbol<*> {
        var s = symbol
        repeat(8) {
            val next: FirBasedSymbol<*> = when {
                s is FirConstructorSymbol -> (s as FirConstructorSymbol).typeAliasConstructorInfo?.originalConstructor?.symbol ?: s
                else -> s
            }
            val unwrapped = if (next is FirCallableSymbol<*>) next.unwrapFakeOverrides<FirCallableSymbol<*>>() else next
            if (unwrapped === s) return s
            s = unwrapped
        }
        return s
    }

    /** Local variables, parameters and local functions: no owner, identified by declaration offset. */
    private fun isTrueLocal(sym: FirCallableSymbol<*>): Boolean =
        sym.isLocal && sym.containingClassLookupTag() == null && sym !is FirConstructorSymbol

    private fun local(sym: FirCallableSymbol<*>): String =
        "local:" + sym.name.asString() + "@" + out.byteOffset(sym.source?.startOffset ?: -1)

    fun callableName(sym: FirCallableSymbol<*>, receiverType: ConeKotlinType?): String {
        if (isTrueLocal(sym)) return local(sym)
        val name = if (sym is FirConstructorSymbol) "<init>" else sym.name.asString()
        return ownerPrefix(sym, receiverType) + name
    }

    /** `pkg/Class.` for members, `pkg/` for top-level callables, empty in the root package. */
    private fun ownerPrefix(sym: FirCallableSymbol<*>, receiverType: ConeKotlinType?): String {
        val tag = sym.containingClassLookupTag()
        if (tag == null) {
            val pkg = sym.callableId?.packageName ?: return ""
            return if (pkg.isRoot) "" else pkg.asString().replace('.', '/') + "/"
        }
        if (Options.commonNames && receiverType != null && isHiddenJdkClass(tag.classId)) {
            val rc = (receiverType.fullyExpandedType(session).lowerBoundIfFlexible() as? ConeClassLikeType)?.lookupTag?.classId
            if (rc != null && jvmAliases.containsKey(rc)) return classId(rc) + "."
        }
        val cls = tag.toSymbol()
        return (if (cls != null) classSymbol(cls) else classId(tag.classId)) + "."
    }

    private fun ConeClassLikeLookupTag.toSymbol(): FirClassLikeSymbol<*>? =
        try { constructClassType(ConeTypeProjection.EMPTY_ARRAY, false).toClassLikeSymbol(session) } catch (_: Exception) { null }

    private fun isHiddenJdkClass(id: ClassId): Boolean {
        val pkg = id.packageFqName.asString()
        return (pkg.startsWith("java.") || pkg.startsWith("javax.") || pkg.startsWith("jdk.")) && !jvmAliases.containsKey(id)
    }

    fun classSymbol(sym: FirClassLikeSymbol<*>): String {
        val id = sym.classId
        if (!id.isLocal) return classId(id)
        val name = if (sym is FirAnonymousObjectSymbol) "<anonymous>" else sym.name.asString()
        return "local:" + name + "@" + out.byteOffset(sym.source?.startOffset ?: -1)
    }

    fun classId(id: ClassId): String = (jvmAliases[id] ?: id).asString()

    private fun typeClass(t: ConeClassLikeType): String {
        val id = t.lookupTag.classId
        if (!id.isLocal) return classId(id)
        val sym = t.toClassLikeSymbol(session) ?: return id.asString()
        return classSymbol(sym)
    }

    fun implicitReceiver(bound: FirBasedSymbol<*>?): String = when (bound) {
        null -> "this@?"
        is FirAnonymousFunctionSymbol -> "lambda@" + out.byteOffset(bound.source?.startOffset ?: -1)
        is FirAnonymousObjectSymbol -> "this@" + classSymbol(bound)
        is FirRegularClassSymbol -> (if (bound.classKind == ClassKind.OBJECT) "obj@" else "this@") + classSymbol(bound)
        is FirReceiverParameterSymbol -> implicitReceiver(bound.containingDeclarationSymbol)
        is FirCallableSymbol<*> -> "ext@" + callableName(bound, null)
        is FirClassLikeSymbol<*> -> "this@" + classSymbol(bound)
        else -> "this@" + bound.javaClass.simpleName
    }

    /** Erased rendering of a declared type: class ids, type parameter names, `?` nullable, `!` platform. */
    fun erase(type: ConeKotlinType): String {
        val t = type.fullyExpandedType(session)
        return when (t) {
            is ConeFlexibleType -> erase(t.lowerBound).removeSuffix("?") + "!"
            is ConeDefinitelyNotNullType -> erase(t.original) + "&Any"
            is ConeClassLikeType -> typeClass(t) + nullMark(t)
            is ConeTypeParameterType -> t.lookupTag.name.asString() + nullMark(t)
            is ConeIntersectionType -> t.intersectedTypes.joinToString("&") { erase(it) }
            else -> t.toString()
        }
    }

    private fun nullMark(t: ConeKotlinType) = if (t.isMarkedNullable) "?" else ""

    private val jvmAliases: Map<ClassId, ClassId>
        get() = aliasCache ?: synchronized(Renderer) { aliasCache ?: buildJvmAliases().also { aliasCache = it } }

    /** JVM `actual typealias` targets mapped back to the Kotlin name (java/util/ArrayList -> kotlin/collections/ArrayList). */
    private fun buildJvmAliases(): Map<ClassId, ClassId> {
        if (!Options.commonNames) return emptyMap()
        val result = HashMap<ClassId, ClassId>()
        val names = session.symbolProvider.symbolNamesProvider
        for (pkg in ALIAS_PACKAGES) {
            val fq = FqName(pkg)
            val classifiers = names.getTopLevelClassifierNamesInPackage(fq) ?: continue
            for (name in classifiers.sortedBy { it.asString() }) {
                val aliasId = ClassId(fq, name)
                val alias = session.symbolProvider.getClassLikeSymbolByClassId(aliasId) as? FirTypeAliasSymbol ?: continue
                val expanded = alias.resolvedExpandedTypeRef.coneType as? ConeClassLikeType ?: continue
                val target = expanded.lookupTag.classId
                if (target.packageFqName.asString().startsWith("java.")) result.putIfAbsent(target, aliasId)
            }
        }
        return result
    }

    companion object {
        @Volatile private var aliasCache: Map<ClassId, ClassId>? = null

        private val ALIAS_PACKAGES = listOf(
            "kotlin", "kotlin.collections", "kotlin.text", "kotlin.io", "kotlin.concurrent",
            "kotlin.concurrent.atomics", "kotlin.coroutines.cancellation", "kotlin.random", "kotlin.time",
        )
    }
}

object Options {
    @Volatile var commonNames: Boolean = true

    /** Whether the compilation ends once the frontend is done. `--diagnostics`
     *  lets it run on: kotlinc reports the frontend's warnings only when the
     *  compilation finishes. */
    @Volatile var stopAfterFrontend: Boolean = true
}
