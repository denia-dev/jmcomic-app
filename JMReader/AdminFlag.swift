import Foundation

/// 管理员构建开关：仓库内默认为 false（正式版不显示云备份入口）；
/// CI 在管理员构建时会把本文件覆写为 true 后再编译。
let ADMIN_BUILD = false
