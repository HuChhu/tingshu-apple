group = "com.local.audiobook"
version = "1.0.0"

plugins {
    kotlin("multiplatform") version "2.0.21"
    id("com.android.library") version "8.7.3"   // 与安卓壳同版 AGP（§19.7.1）
}

kotlin {
    iosArm64() {
        binaries.framework {
            baseName = "shared"   // 契约 v1.1 / Swift `import shared` / 方案集统一名；与 rootProject.name=shared-core 解耦
        }
    }   // CI 交叉编译 framework/klib（devops T07 定谳：linux-x86_64 可编译、link 需 macOS）
    jvm()   // CLI 入口经 jvmJar -jar；AGP 介入后 application/withJava() 不可用（M1 坑已记）
    androidTarget()   // T03：安卓壳消费 shared（compileSdk 34 本机验证；壳侧 36 由 ECS 构建）
    jvmToolchain(17)

    sourceSets {
        commonMain.dependencies {
            implementation("org.jetbrains.kotlinx:kotlinx-serialization-json:1.7.3")
            implementation("org.jetbrains.kotlinx:kotlinx-coroutines-core:1.9.0")
            implementation("org.jetbrains.kotlinx:atomicfu:0.24.0")
            implementation("io.ktor:ktor-client-core:3.0.3")
        }
        jvmMain.dependencies {
            implementation("io.ktor:ktor-client-cio:3.0.3")
        }
        jvmTest.dependencies {
            implementation(kotlin("test"))
        }
    }
}

// CLI 入口：jvmJar manifest Main-Class（替代 application 插件）
tasks.named<org.gradle.jvm.tasks.Jar>("jvmJar") {
    manifest { attributes["Main-Class"] = "com.local.audiobook.core.MainKt" }
}

android {
    namespace = "com.local.audiobook.sharedcore"
    compileSdk = 34   // 本机可用平台；壳侧 backdrop 强制 36 的约束只影响壳模块（AGENTS §13.6）
    defaultConfig { minSdk = 26 }
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
}
