repositories {
    // 只有 paper 需要 Paper 的仓库；common 不依赖 Paper。
    maven("https://repo.papermc.io/repository/maven-public/")
}

dependencies {
    implementation(project(":common"))

    // Paper 自带 Gson、SnakeYAML 和 Adventure，所以只用 compileOnly；插件 jar 里只额外打包 common。
    compileOnly("io.papermc.paper:paper-api:1.21.11-R0.1-SNAPSHOT")

    // 测试里没有 Paper 服务端，需要自己带上 paper-api 里的 Gson 和 YamlConfiguration。
    testImplementation("io.papermc.paper:paper-api:1.21.11-R0.1-SNAPSHOT")
    testImplementation("org.junit.jupiter:junit-jupiter:6.1.3")
    testRuntimeOnly("org.junit.platform:junit-platform-launcher:6.1.3")
}

base {
    archivesName = "gtmc-paper"
}

tasks.withType<JavaCompile> {
    // 用 release 而不是 toolchain：不依赖 Gradle 去下载 JDK，JDK 低于 21 时直接编译失败。
    options.release = 21
}

val pluginVersion = version.toString()

tasks.processResources {
    // plugin.yml 里的 ${version} 在构建时替换，版本号只在根项目维护一处。
    inputs.property("version", pluginVersion)
    filesMatching("plugin.yml") {
        expand("version" to pluginVersion)
    }
}

tasks.jar {
    // common 不是独立的插件，运行时没人替我们加载它，所以把它的类直接放进插件 jar。
    // 只有 common 在 runtimeClasspath 里：Paper 和 Gson 都是 compileOnly。
    from({ configurations.runtimeClasspath.get().map { zipTree(it) } })
}
