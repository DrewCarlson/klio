package klio.semaoracle

import org.jetbrains.kotlin.backend.common.extensions.IrGenerationExtension
import org.jetbrains.kotlin.backend.common.extensions.IrPluginContext
import org.jetbrains.kotlin.compiler.plugin.CompilerPluginRegistrar
import org.jetbrains.kotlin.ir.declarations.IrModuleFragment
import org.jetbrains.kotlin.config.CompilerConfiguration
import org.jetbrains.kotlin.diagnostics.DiagnosticReporter
import org.jetbrains.kotlin.fir.FirSession
import org.jetbrains.kotlin.fir.analysis.checkers.MppCheckerKind
import org.jetbrains.kotlin.fir.analysis.checkers.context.CheckerContext
import org.jetbrains.kotlin.fir.analysis.checkers.declaration.DeclarationCheckers
import org.jetbrains.kotlin.fir.analysis.checkers.declaration.FirDeclarationChecker
import org.jetbrains.kotlin.fir.analysis.extensions.FirAdditionalCheckersExtension
import org.jetbrains.kotlin.fir.declarations.FirFile
import org.jetbrains.kotlin.fir.extensions.FirExtensionRegistrar
import org.jetbrains.kotlin.fir.extensions.FirExtensionRegistrarAdapter
import java.io.File
import java.util.concurrent.ConcurrentHashMap

/** Where the plugin delivers each file's sites. The driver registers a collector per
 *  canonical source path before compiling that file and removes it afterwards. */
object OracleSink {
    val collectors = ConcurrentHashMap<String, FileCollector>()

    fun canonical(path: String): String = try {
        File(path).canonicalPath
    } catch (_: Exception) {
        File(path).absolutePath
    }
}

class OracleRegistrar : CompilerPluginRegistrar() {
    override val pluginId: String get() = "klio.sema-oracle"
    override val supportsK2: Boolean get() = true

    override fun ExtensionStorage.registerExtensions(configuration: CompilerConfiguration) {
        FirExtensionRegistrarAdapter.registerExtension(OracleFirRegistrar())
        IrGenerationExtension.registerExtension(StopAfterFrontend)
    }
}

/**
 * The oracle only needs resolved FIR. Reaching IR generation means the frontend
 * reported no errors, so the compilation ends here: JVM lowering, code generation
 * and output writing are skipped. The compiler reports the throw as an internal
 * error; the driver recognizes [FrontendDone] and counts the file as compiled.
 */
object StopAfterFrontend : IrGenerationExtension {
    override fun generate(moduleFragment: IrModuleFragment, pluginContext: IrPluginContext) {
        throw FrontendDone()
    }
}

class FrontendDone : RuntimeException(FrontendDone.MARKER) {
    companion object {
        const val MARKER = "klio.semaoracle.FrontendDone"
    }
}

class OracleFirRegistrar : FirExtensionRegistrar() {
    override fun ExtensionRegistrarContext.configurePlugin() {
        +::OracleCheckers
    }
}

class OracleCheckers(session: FirSession) : FirAdditionalCheckersExtension(session) {
    override val declarationCheckers: DeclarationCheckers = object : DeclarationCheckers() {
        override val fileCheckers: Set<FirDeclarationChecker<FirFile>> = setOf(OracleFileChecker)
    }
}

object OracleFileChecker : FirDeclarationChecker<FirFile>(MppCheckerKind.Common) {
    context(context: CheckerContext, reporter: DiagnosticReporter)
    override fun check(declaration: FirFile) {
        val path = declaration.sourceFile?.path ?: return
        val collector = OracleSink.collectors[OracleSink.canonical(path)] ?: return
        SiteWalker(context.session, context.scopeSession, collector).walkFile(declaration)
    }
}
