allprojects {
    repositories {
        google()
        mavenCentral()
    }
}

val newBuildDir: Directory =
    rootProject.layout.buildDirectory
        .dir("../../build")
        .get()
rootProject.layout.buildDirectory.value(newBuildDir)

subprojects {
    val newSubprojectBuildDir: Directory = newBuildDir.dir(project.name)
    project.layout.buildDirectory.value(newSubprojectBuildDir)
}
// open_wake_word links and packages its own onnxruntime 1.17.1, the vad package uses 1.22.0, and
// the APK can hold only one libonnxruntime.so. vad needs the newer library (it asks for API 22,
// which 1.17.1 does not have), while open_wake_word only uses API 17 and runs on it. So the
// plugin's copy is replaced by the 1.22.0 one before it is built, which makes both copies the same.
subprojects {
    if (project.name == "open_wake_word") {
        val useNewerOnnx: Project.() -> Unit = {
            val aar = configurations
                .detachedConfiguration(
                    dependencies.create("com.microsoft.onnxruntime:onnxruntime-android:1.22.0@aar"),
                ).apply { isTransitive = false }
                .singleFile
            copy {
                from(zipTree(aar))
                include("jni/**")
                into(layout.buildDirectory.get().asFile.resolve("onnxruntime"))
            }
        }
        if (state.executed) useNewerOnnx() else afterEvaluate { useNewerOnnx() }
    }
}

subprojects {
    project.evaluationDependsOn(":app")
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
