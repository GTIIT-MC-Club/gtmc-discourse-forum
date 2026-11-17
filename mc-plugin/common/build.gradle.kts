// 各平台适配层共用的逻辑。只依赖 JDK 和 Gson，不许引用 Bukkit/Paper 或任何加载器的类。
dependencies {
    // 运行时 Gson 由各 MC 服务端自带（Paper 和原版都带），所以只用 compileOnly，不打包。
    // 版本取 Minecraft 1.20.x 自带的 2.10.1：编译时就用不到更新版本才有的 API。
    compileOnly("com.google.code.gson:gson:2.10.1")

    testImplementation("com.google.code.gson:gson:2.10.1")
    testImplementation("org.junit.jupiter:junit-jupiter:6.1.3")
    testRuntimeOnly("org.junit.platform:junit-platform-launcher:6.1.3")
}

tasks.withType<JavaCompile> {
    // Fabric/Forge 的 1.20.x 服跑在 Java 17 上。release 会同时限制可用的语言特性和 JDK API，
    // 误用 17 以后的 API 会直接编译失败。
    options.release = 17
}

tasks.test {
    // 与生产环境一致：让 java.net.http 允许手动设置 Host 头，见 HeartbeatClient。
    systemProperty("jdk.httpclient.allowRestrictedHeaders", "host")
}
