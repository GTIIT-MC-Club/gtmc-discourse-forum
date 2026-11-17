dependencies {
    // Paper 自带 Gson、SnakeYAML 和 Adventure，运行时不再打包任何依赖，所以只用 compileOnly。
    compileOnly("io.papermc.paper:paper-api:1.21.11-R0.1-SNAPSHOT")

    // 测试里没有 Paper 服务端，需要自己带上 paper-api 里的 Gson 和 YamlConfiguration。
    testImplementation("io.papermc.paper:paper-api:1.21.11-R0.1-SNAPSHOT")
    testImplementation("org.junit.jupiter:junit-jupiter:6.1.3")
    testRuntimeOnly("org.junit.platform:junit-platform-launcher:6.1.3")
}

base {
    // 保持 M1 的产物名 gtmc-paper-<版本>.jar，而不是目录名 paper-<版本>.jar。
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

tasks.test {
    // 与生产环境一致：让 java.net.http 允许手动设置 Host 头，见 HeartbeatClient。
    systemProperty("jdk.httpclient.allowRestrictedHeaders", "host")
}
