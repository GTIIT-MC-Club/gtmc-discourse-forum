plugins {
    id("com.diffplug.spotless") version "8.11.0"
}

// 所有子项目共用的版本号和格式规则放在这里，子项目的 build.gradle.kts 只写各自特有的部分。
allprojects {
    group = "org.gtmc"
    version = "0.1.0"
}

subprojects {
    apply(plugin = "java")

    repositories {
        mavenCentral()
    }

    tasks.withType<JavaCompile> {
        options.encoding = "UTF-8"
    }

    tasks.withType<Test> {
        useJUnitPlatform()
    }
}

// Spotless 在根项目里解析 google-java-format，用不到 subprojects 里声明的仓库。
repositories {
    mavenCentral()
}

spotless {
    java {
        target("*/src/**/*.java")
        googleJavaFormat("2.0.0")
    }
}
