package klio.semaoracle

import com.intellij.psi.PsiElement
import org.jetbrains.kotlin.KtFakeSourceElementKind
import org.jetbrains.kotlin.KtPsiSourceElement
import org.jetbrains.kotlin.KtRealSourceElementKind
import org.jetbrains.kotlin.KtSourceElement
import org.jetbrains.kotlin.descriptors.ClassKind
import org.jetbrains.kotlin.fir.FirElement
import org.jetbrains.kotlin.fir.FirSession
import org.jetbrains.kotlin.fir.declarations.FirFile
import org.jetbrains.kotlin.fir.expressions.*
import org.jetbrains.kotlin.fir.references.*
import org.jetbrains.kotlin.fir.symbols.FirBasedSymbol
import org.jetbrains.kotlin.fir.symbols.impl.*
import org.jetbrains.kotlin.fir.visitors.FirVisitorVoid
import org.jetbrains.kotlin.fir.resolve.providers.symbolProvider
import org.jetbrains.kotlin.fir.declarations.FirResolvePhase
import org.jetbrains.kotlin.fir.resolve.ScopeSession
import org.jetbrains.kotlin.fir.resolve.fullyExpandedType
import org.jetbrains.kotlin.fir.resolve.toClassSymbol
import org.jetbrains.kotlin.fir.scopes.getFunctions
import org.jetbrains.kotlin.fir.scopes.unsubstitutedScope
import org.jetbrains.kotlin.fir.types.*
import org.jetbrains.kotlin.name.Name
import org.jetbrains.kotlin.name.StandardClassIds
import org.jetbrains.kotlin.lexer.KtTokens
import org.jetbrains.kotlin.psi.*
import java.util.IdentityHashMap

/**
 * Walks one resolved FIR file and records every resolved reference as a [Site].
 *
 * Anchors are computed from PSI (the driver compiles with `-Xuse-fir-lt=false`) so
 * operator-convention sites can be pinned to the whole operator expression, which
 * is what KLIO's AST keeps.
 */
class SiteWalker(val session: FirSession, val scopeSession: ScopeSession, val out: FileCollector) : FirVisitorVoid() {
    private val seen: MutableSet<FirElement> = java.util.Collections.newSetFromMap(IdentityHashMap())
    private val receiverQualifiers: MutableSet<FirResolvedQualifier> = java.util.Collections.newSetFromMap(IdentityHashMap())
    private val render = Renderer(session, out)

    fun walkFile(file: FirFile) {
        out.visited = true
        file.accept(this)
    }

    override fun visitElement(element: FirElement) {
        if (!seen.add(element)) return
        when (element) {
            is FirAnnotation -> return
            is FirVariableAssignment -> {
                onAssignment(element)
                return
            }
            is FirThisReceiverExpression -> return
            is FirQualifiedAccessExpression -> onAccess(element)
            is FirDelegatedConstructorCall -> onDelegatedConstructor(element)
            is FirEqualityOperatorCall -> onEquality(element)
            is FirResolvedQualifier -> onQualifier(element)
            is FirGetClassCall -> element.argumentList.arguments.forEach { if (it is FirResolvedQualifier) receiverQualifiers.add(it) }
            else -> {}
        }
        element.acceptChildren(this)
    }

    // ---------------------------------------------------------------- sites

    private fun onAccess(e: FirQualifiedAccessExpression) {
        val ref = e.calleeReference
        if (ref is FirThisReference || ref is FirSuperReference) return
        markReceiverQualifier(e)
        val sym = resolvedSymbol(ref) ?: return
        val kind = kindOf(e, ref, sym)
        debug(e, ref, sym, kind)
        if (kind == null) return
        if (isSynthetic(sym)) return
        val anchor = anchorFor(kind, ref.source, e.source) ?: return debugSkip("no anchor", e)
        emit(anchor, kind, sym, receiverOrigin(e.dispatchReceiver), receiverOrigin(e.extensionReceiver), e.dispatchReceiver?.resolvedType)
    }

    private fun onAssignment(a: FirVariableAssignment) {
        val written = a.lValue
        // `x += 1`, `x++`: the lvalue refers back to the read of `x` that feeds the operator.
        val desugared = written is FirDesugaredAssignmentValueReferenceExpression
        val lValue = if (written is FirDesugaredAssignmentValueReferenceExpression) written.expressionRef.value else written
        if (lValue is FirQualifiedAccessExpression) {
            if (!desugared) seen.add(lValue)
            markReceiverQualifier(lValue)
            val ref = lValue.calleeReference
            val sym = resolvedSymbol(ref)
            debug(lValue, ref, sym, "write")
            if (sym != null && !isSynthetic(sym)) {
                val anchor = anchorFor("write", ref.source, lValue.source ?: a.source)
                if (anchor != null) {
                    emit(
                        anchor, "write", sym, receiverOrigin(lValue.dispatchReceiver), receiverOrigin(lValue.extensionReceiver),
                        lValue.dispatchReceiver?.resolvedType,
                    )
                }
            }
            if (!desugared) {
                lValue.explicitReceiver?.accept(this)
                lValue.contextArguments.forEach { it.accept(this) }
            }
        } else {
            lValue.accept(this)
        }
        a.rValue.accept(this)
    }

    private fun onDelegatedConstructor(c: FirDelegatedConstructorCall) {
        val ref = c.calleeReference
        val sym = resolvedSymbol(ref) ?: return
        debug(c, ref, sym, "ctor")
        val src = c.source ?: return
        // Implicit delegation (`class A`, a secondary constructor without `: this()/super()`)
        // has no syntax of its own.
        if (src.kind is KtFakeSourceElementKind) return
        val anchor = delegationAnchor(psi(src)) ?: return debugSkip("no anchor", c)
        emit(anchor, "ctor", sym, receiverOrigin(c.dispatchReceiver), "-")
    }

    private fun onEquality(c: FirEqualityOperatorCall) {
        if (c.operation != FirOperation.EQ && c.operation != FirOperation.NOT_EQ) return
        val args = c.argumentList.arguments
        if (args.any { it is FirLiteralExpression && it.value == null }) return
        val sym = equalsFor(args[0].resolvedType, 0)
        debug(c, c.calleeReference, sym, "equals")
        if (sym == null) return
        val anchor = equalityAnchor(psi(c.source)) ?: return debugSkip("no anchor", c)
        emit(anchor, "equals", sym, "expr", "-", args[0].resolvedType)
    }

    /** FIR does not bind `==` to a member; the oracle names the `equals(Any?)` the left operand's type sees. */
    private fun equalsFor(type: ConeKotlinType, depth: Int): FirNamedFunctionSymbol? {
        var t: ConeKotlinType = type.fullyExpandedType(session).lowerBoundIfFlexible()
        if (t is ConeDefinitelyNotNullType) t = t.original
        val cls: FirClassSymbol<*>? = when (t) {
            is ConeClassLikeType -> t.lookupTag.toClassSymbol(session)
            is ConeTypeParameterType -> {
                val bound = t.lookupTag.typeParameterSymbol.resolvedBounds.firstOrNull()?.coneType
                if (bound != null && depth < 8) return equalsFor(bound, depth + 1)
                null
            }
            is ConeIntersectionType -> t.intersectedTypes.firstOrNull()?.let { if (depth < 8) return equalsFor(it, depth + 1) else null }
            else -> null
        }
        val owner = cls ?: session.symbolProvider.getClassLikeSymbolByClassId(StandardClassIds.Any) as? FirClassSymbol<*> ?: return null
        val scope = owner.unsubstitutedScope(session, scopeSession, false, FirResolvePhase.STATUS)
        return scope.getFunctions(EQUALS).firstOrNull {
            it.valueParameterSymbols.size == 1 && it.receiverParameterSymbol == null && it.contextParameterSymbols.isEmpty()
        }
    }

    private fun markReceiverQualifier(e: FirQualifiedAccessExpression) {
        val q = e.explicitReceiver as? FirResolvedQualifier ?: return
        if (!receiverQualifiers.add(q)) return
        if (q === e.dispatchReceiver || q === e.extensionReceiver) emitQualifier(q)
    }

    private fun onQualifier(q: FirResolvedQualifier) {
        if (q in receiverQualifiers) return
        emitQualifier(q)
    }

    private fun emitQualifier(q: FirResolvedQualifier) {
        val obj = objectOf(q) ?: return
        val src = q.source ?: return
        if (src.kind !is KtRealSourceElementKind && src.kind != KtFakeSourceElementKind.ImplicitInvokeCall) return
        val p = psi(src) ?: return
        val anchor = nameAnchor(p)
        record(anchor, "read", "object:" + render.classSymbol(obj), "-", "-")
    }

    private fun objectOf(q: FirResolvedQualifier): FirRegularClassSymbol? {
        val sym = q.qualifierSymbol as? FirRegularClassSymbol ?: return null
        if (q.resolvedToCompanionObject) return sym.resolvedCompanionObjectSymbol
        return if (sym.classKind == ClassKind.OBJECT) sym else null
    }

    // ---------------------------------------------------------------- kinds

    private fun resolvedSymbol(ref: FirReference): FirBasedSymbol<*>? {
        if (ref is FirResolvedErrorReference || ref is FirErrorNamedReference) {
            out.unresolved++
            return null
        }
        return (ref as? FirResolvedNamedReference)?.resolvedSymbol
    }

    private fun kindOf(e: FirQualifiedAccessExpression, ref: FirReference, sym: FirBasedSymbol<*>): String? {
        // A bare name shares its PSI with its reference; FIR marks the reference fake and
        // keeps the real kind on the expression.
        val calleeKind = ref.source?.kind.let {
            if (it == KtFakeSourceElementKind.ReferenceInAtomicQualifiedAccess) e.source?.kind else it
        }
        return when (e) {
            is FirCallableReferenceAccess -> if (calleeKind is KtFakeSourceElementKind) null else "ref"
            // `val (_, b) = p`: the language does not call component1 for `_`.
            is FirComponentCall -> if ((psi(e.source) as? KtDestructuringDeclarationEntry)?.name == "_") null else "component${e.componentIndex}"
            is FirImplicitInvokeCall -> "invoke"
            is FirFunctionCall -> when {
                // `a !in b` is `!b.contains(a)`; the `not` is not written.
                e.source?.kind == KtFakeSourceElementKind.DesugaredInvertedContains -> null
                sym is FirConstructorSymbol -> "ctor"
                e.origin == FirFunctionCallOrigin.Operator -> (ref as FirNamedReference).name.asString()
                calleeKind is KtFakeSourceElementKind -> conventionFor(calleeKind, (ref as FirNamedReference).name.asString())
                else -> "call"
            }
            is FirPropertyAccessExpression -> when {
                calleeKind == null || calleeKind is KtRealSourceElementKind -> "read"
                calleeKind is KtFakeSourceElementKind && readKeptFor(calleeKind) -> "read"
                else -> null
            }
            else -> null
        }
    }

    private fun conventionFor(kind: KtFakeSourceElementKind, name: String): String? = when (kind) {
        KtFakeSourceElementKind.DesugaredForLoop,
        KtFakeSourceElementKind.ArrayAccessNameReference,
        KtFakeSourceElementKind.CalleeReferenceForOperatorOfCall,
        KtFakeSourceElementKind.ImplicitInvokeCall,
        KtFakeSourceElementKind.DesugaredPlusAssign,
        KtFakeSourceElementKind.DesugaredMinusAssign,
        KtFakeSourceElementKind.DesugaredTimesAssign,
        KtFakeSourceElementKind.DesugaredDivAssign,
        KtFakeSourceElementKind.DesugaredRemAssign,
        KtFakeSourceElementKind.GeneratedComparisonExpression,
        KtFakeSourceElementKind.WhenCondition -> name
        is KtFakeSourceElementKind.DesugaredIncrementOrDecrement -> name
        is KtFakeSourceElementKind.DesugaredAugmentedAssign -> name
        is KtFakeSourceElementKind.DelegatedPropertyAccessor -> name
        KtFakeSourceElementKind.WrappedDelegate -> name
        else -> null
    }

    private fun readKeptFor(kind: KtFakeSourceElementKind): Boolean = when (kind) {
        KtFakeSourceElementKind.DesugaredPlusAssign,
        KtFakeSourceElementKind.DesugaredMinusAssign,
        KtFakeSourceElementKind.DesugaredTimesAssign,
        KtFakeSourceElementKind.DesugaredDivAssign,
        KtFakeSourceElementKind.DesugaredRemAssign,
        KtFakeSourceElementKind.ImplicitInvokeCall,
        KtFakeSourceElementKind.DesugaredNameBasedDestructuring -> true
        is KtFakeSourceElementKind.DesugaredAugmentedAssign -> true
        is KtFakeSourceElementKind.DesugaredIncrementOrDecrement -> true
        else -> false
    }

    /** Compiler temporaries (`<iterator>`, `<destruct>`, `x$delegate`, ...). */
    private fun isSynthetic(sym: FirBasedSymbol<*>): Boolean {
        if (sym is FirDelegateFieldSymbol) return true
        if (sym is FirCallableSymbol<*>) {
            val name = sym.name
            if (name.isSpecial) return true
        }
        return false
    }

    // ---------------------------------------------------------------- anchors

    private fun psi(src: KtSourceElement?): PsiElement? = (src as? KtPsiSourceElement)?.psi

    private fun anchorFor(kind: String, callee: KtSourceElement?, node: KtSourceElement?): PsiElement? {
        val p = psi(callee) ?: psi(node) ?: return null
        val n = psi(node)
        return when (kind) {
            "call", "read", "write", "ref", "ctor" -> nameAnchor(p)
            "invoke" -> invokeAnchor(n ?: p)
            "iterator", "hasNext", "next" -> forRangeAnchor(p)
            "getValue", "setValue", "provideDelegate" -> delegateAnchor(p)
            "get", "set" -> arrayAccessAnchor(p) ?: n?.let { arrayAccessAnchor(it) }
            "inc", "dec" -> p.selfOrParent<KtUnaryExpression>()
            "equals" -> equalityAnchor(p)
            "contains" -> p.nearest { it is KtBinaryExpression || it is KtWhenConditionInRange }
            else -> if (kind.startsWith("component")) destructuringAnchor(p) else operatorAnchor(p)
        }
    }

    private fun nameAnchor(p: PsiElement): PsiElement = when (p) {
        is KtSimpleNameExpression -> p
        is KtDestructuringDeclarationEntry -> p.nameIdentifier ?: p
        is KtQualifiedExpression -> p.selectorExpression?.let { nameAnchor(it) } ?: p
        is KtCallExpression -> p.calleeExpression?.let { nameAnchor(it) } ?: p
        is KtCallableReferenceExpression -> nameAnchor(p.callableReference)
        is KtParenthesizedExpression -> p.expression?.let { nameAnchor(it) } ?: p
        is KtBinaryExpression -> if (p.operationToken in KtTokens.ALL_ASSIGNMENTS) p.left?.let { nameAnchor(it) } ?: p else p
        is KtUnaryExpression -> p.baseExpression?.let { nameAnchor(it) } ?: p
        is KtLabeledExpression -> p.baseExpression?.let { nameAnchor(it) } ?: p
        is KtAnnotatedExpression -> p.baseExpression?.let { nameAnchor(it) } ?: p
        is KtConstructorCalleeExpression -> p.constructorReferenceExpression ?: p
        else -> p
    }

    private fun arrayAccessAnchor(p: PsiElement): PsiElement? {
        var q: PsiElement? = p
        // `a[i] += v` and `a[i] = v`: the call is sourced on the assignment.
        if (q is KtBinaryExpression && q.operationToken in KtTokens.ALL_ASSIGNMENTS) q = q.left
        while (q is KtParenthesizedExpression) q = q.expression
        return (q as? KtArrayAccessExpression) ?: p.selfOrParent<KtArrayAccessExpression>()
    }

    private fun invokeAnchor(p: PsiElement): PsiElement {
        var q: PsiElement = p
        if (q is KtQualifiedExpression) q = q.selectorExpression ?: q
        if (q is KtCallExpression) return q.calleeExpression ?: q
        return q
    }

    private fun forRangeAnchor(p: PsiElement): PsiElement? {
        val loop = p.selfOrParent<KtForExpression>() ?: return p
        return loop.loopRange ?: p
    }

    private fun delegateAnchor(p: PsiElement): PsiElement? {
        if (p is KtProperty) return p.delegateExpression ?: p
        val d = p.selfOrParent<KtPropertyDelegate>()
        return d?.expression ?: p
    }

    private fun destructuringAnchor(p: PsiElement): PsiElement {
        val entry = p.selfOrParent<KtDestructuringDeclarationEntry>() ?: return p
        return entry.nameIdentifier ?: entry
    }

    private fun equalityAnchor(p: PsiElement?): PsiElement? {
        p ?: return null
        return p.nearest { it is KtBinaryExpression || it is KtWhenConditionWithExpression } ?: p
    }

    private fun operatorAnchor(p: PsiElement): PsiElement =
        p.selfOrParent<KtOperationExpression>() as PsiElement? ?: p

    private fun delegationAnchor(p: PsiElement?): PsiElement? = when (p) {
        null -> null
        is KtConstructorDelegationCall -> p.calleeExpression ?: p
        is KtSuperTypeCallEntry -> {
            val ref = p.calleeExpression.constructorReferenceExpression
            if (ref != null && ref.textLength > 0) ref else p.getStrictParentOfType<KtEnumEntry>()?.nameIdentifier ?: p
        }
        is KtEnumEntry -> p.nameIdentifier ?: p
        else -> p
    }

    // ---------------------------------------------------------------- receivers

    private fun receiverOrigin(r: FirExpression?): String {
        var x = r ?: return "-"
        while (x is FirSmartCastExpression) x = x.originalExpression
        if (x is FirThisReceiverExpression && x.isImplicit) return render.implicitReceiver(x.calleeReference.boundSymbol)
        val src = x.source
        if (x is FirPropertyAccessExpression && src?.kind == KtFakeSourceElementKind.ImplicitContextParameterArgument) {
            val s = (x.calleeReference as? FirResolvedNamedReference)?.resolvedSymbol
            if (s is FirValueParameterSymbol) return "ctx@" + s.name.asString()
        }
        // A type used as a namespace (static member, enum entry) supplies no receiver object.
        if (x is FirResolvedQualifier && objectOf(x) == null) return "-"
        return "expr"
    }

    // ---------------------------------------------------------------- output

    private fun emit(
        anchor: PsiElement, kind: String, sym: FirBasedSymbol<*>, dispatch: String, extension: String,
        receiverType: ConeKotlinType? = null,
    ) {
        val target = render.target(sym, receiverType) ?: return
        record(anchor, kind, target, dispatch, extension)
    }

    private fun record(anchor: PsiElement, kind: String, target: String, dispatch: String, extension: String) {
        val r = anchor.textRange
        out.sites.add(Site(out.byteOffset(r.startOffset), out.byteOffset(r.endOffset), kind, target, dispatch, extension))
    }

    private fun debug(e: FirElement, ref: FirReference?, sym: FirBasedSymbol<*>?, kind: String?) {
        if (!out.debug) return
        val origin = (e as? FirFunctionCall)?.origin?.name ?: ""
        val recv = (e as? FirQualifiedAccessExpression)?.let {
            " disp=" + describeRecv(it.dispatchReceiver) + " ext=" + describeRecv(it.extensionReceiver)
        } ?: ""
        out.debugLines.add(
            "#dbg ${e.javaClass.simpleName} src=${describe(e.source)} callee=${describe(ref?.source)} " +
                "ref=${ref?.javaClass?.simpleName} sym=${sym?.javaClass?.simpleName}:${sym?.let { render.target(it) }} " +
                "origin=$origin kind=$kind$recv"
        )
    }

    private fun debugSkip(why: String, e: FirElement) {
        if (out.debug) out.debugLines.add("#dbg skip $why ${e.javaClass.simpleName} ${describe(e.source)}")
    }

    private fun describeRecv(r: FirExpression?): String {
        r ?: return "-"
        val extra = when (r) {
            is FirThisReceiverExpression -> "(implicit=${r.isImplicit},bound=${r.calleeReference.boundSymbol?.javaClass?.simpleName})"
            else -> ""
        }
        return r.javaClass.simpleName + extra + "[" + describe(r.source) + "]"
    }

    private fun describe(s: KtSourceElement?): String {
        s ?: return "null"
        val kind = when (val k = s.kind) {
            is KtRealSourceElementKind -> "real"
            else -> k.javaClass.name.substringAfter("KtFakeSourceElementKind$")
        }
        val p = psi(s)
        val text = p?.text?.replace("\n", "\\n")?.let { if (it.length > 40) it.take(40) + "..." else it } ?: ""
        return "$kind:${p?.javaClass?.simpleName}@${s.startOffset}-${s.endOffset}'$text'"
    }
}

private val EQUALS = Name.identifier("equals")

inline fun <reified T : PsiElement> PsiElement.selfOrParent(): T? {
    var p: PsiElement? = this
    while (p != null && p !is KtFile) {
        if (p is T) return p
        p = p.parent
    }
    return null
}

inline fun <reified T : PsiElement> PsiElement.getStrictParentOfType(): T? = parent?.selfOrParent<T>()

inline fun PsiElement.nearest(match: (PsiElement) -> Boolean): PsiElement? {
    var p: PsiElement? = this
    while (p != null && p !is KtFile) {
        if (match(p)) return p
        p = p.parent
    }
    return null
}
