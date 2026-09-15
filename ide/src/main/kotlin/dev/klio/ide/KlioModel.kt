package dev.klio.ide

import com.google.gson.Gson
import com.google.gson.annotations.SerializedName

/**
 * The project model `klio ide model` prints. The CLI owns every answer about
 * how a project composes; this is a transport record, not a second model.
 */
data class KlioProjectModel(
    val schema: Int = 0,
    val kotlin: String = "",
    val languageVersion: String = "",
    val project: KlioProjectInfo = KlioProjectInfo(),
    val modules: List<KlioModule> = emptyList(),
    val problems: List<String> = emptyList(),
)

data class KlioProjectInfo(
    val root: String = "",
    val name: String = "",
    val hasManifest: Boolean = false,
)

data class KlioModule(
    val id: String = "",
    /** `source` for the user's own code, `library` for a materialised pack. */
    val kind: String = "source",
    /** `klio`, or `common` for a root that declares `expect`. */
    val platform: String = "klio",
    val contentRoots: List<String> = emptyList(),
    /** Refinement edges: the modules whose `expect` declarations this one actualises. */
    @SerializedName("dependsOn") val dependsOn: List<String> = emptyList(),
    val dependencies: List<String> = emptyList(),
    val compilerArguments: List<String> = emptyList(),
    val isTest: Boolean = false,
    val readOnly: Boolean = false,
    /** `off` for materialised library source, which klio may legitimately diverge on. */
    val highlighting: String = "full",
    val feature: String? = null,
) {
    val isLibrary: Boolean get() = kind == "library"
}

/** The schema this build understands. A newer document is refused, never guessed at. */
const val KLIO_MODEL_SCHEMA = 1

object KlioModelParser {
    private val gson = Gson()

    fun parse(json: String): KlioProjectModel {
        val model = gson.fromJson(json, KlioProjectModel::class.java)
            ?: throw KlioCliException("klio ide model printed nothing")
        if (model.schema != KLIO_MODEL_SCHEMA) {
            throw KlioCliException(
                "this klio build emits project model schema ${model.schema}, " +
                    "and the plugin understands $KLIO_MODEL_SCHEMA. Update whichever is older."
            )
        }
        return model
    }
}
