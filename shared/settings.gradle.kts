pluginManagement {
    repositories {
        // 官方源优先：CI 跑在 GitHub runner（海外），阿里云镜像反而慢且会超时
        gradlePluginPortal()
        google()
        mavenCentral()
        // 阿里云作为后备（本地开发在国内时更快）
        maven("https://maven.aliyun.com/repository/gradle-plugin")
        maven("https://maven.aliyun.com/repository/google")
        maven("https://maven.aliyun.com/repository/public")
    }
}
dependencyResolutionManagement {
    repositories {
        google()
        mavenCentral()
        maven("https://maven.aliyun.com/repository/google")
        maven("https://maven.aliyun.com/repository/public")
    }
}
rootProject.name = "shared-core"
