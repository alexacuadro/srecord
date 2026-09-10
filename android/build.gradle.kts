buildscript {
    val kotlin_version = "2.1.0"
    repositories {
        maven { url = uri("https://download.shorebird.dev/flutter_infra_release") }
        maven { url = uri("https://storage.googleapis.com/download.flutter.io") }
        maven { url = uri("https://maven.aliyun.com/repository/public") }
        maven { url = uri("https://maven.aliyun.com/repository/google") }
        maven { url = uri("https://storage.flutter-io.cn/download.flutter.io") }
        maven { url = uri("https://repo.huaweicloud.com/repository/maven/") }
        maven { url = uri("https://mirrors.163.com/maven/repository/maven-public/") }
        google()
        mavenCentral()
    }
    dependencies {
        classpath("org.jetbrains.kotlin:kotlin-gradle-plugin:$kotlin_version")
        classpath("com.android.tools.build:gradle:8.6.0")
    }
}

allprojects {
    repositories {
        maven { url = uri("https://download.shorebird.dev/flutter_infra_release") }
        maven { url = uri("https://storage.googleapis.com/download.flutter.io") }
        maven { url = uri("https://maven.aliyun.com/repository/public") }
        maven { url = uri("https://maven.aliyun.com/repository/google") }
        maven { url = uri("https://storage.flutter-io.cn/download.flutter.io") }
        maven { url = uri("https://repo.huaweicloud.com/repository/maven/") }
        maven { url = uri("https://mirrors.163.com/maven/repository/maven-public/") }
        google()
        mavenCentral()
        maven { url = uri("https://jitpack.io") }
    }
}

rootProject.layout.buildDirectory.set(file("${project.projectDir}/../build"))
subprojects {
    project.layout.buildDirectory.set(file("${rootProject.layout.buildDirectory.get().asFile}/${project.name}"))
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
