pluginManagement {
    repositories {
        maven("https://maven.aliyun.com/repository/gradle-plugin")
        maven("https://maven.aliyun.com/repository/google")   // AGP
        maven("https://maven.aliyun.com/repository/public")
        gradlePluginPortal()
        mavenCentral()
        google()
    }
}
dependencyResolutionManagement {
    repositories {
        maven("https://maven.aliyun.com/repository/public")
        maven("https://maven.aliyun.com/repository/google")   // AGP 工具链组件（lint-gradle 等）
        mavenCentral()
        google()
    }
}
rootProject.name = "shared-core"
