import Foundation

struct AppConfiguration {
    static let shared = AppConfiguration()

    // Replace with real Livelox OAuth values.
    let liveloxClientId = "LoxBridge"
    let liveloxAuthURL = "https://api.livelox.com/oauth2/authorize"
    let liveloxTokenURL = "https://api.livelox.com/oauth2/token"
    let liveloxRedirectScheme = "loxbrige"
    let liveloxRedirectURI = "loxbrige://oauth/callback"
    let liveloxScopes = "routes.import"

    let liveloxUserInfoURL = "https://api.livelox.com/oauth2/userinfo"
    let liveloxAPIBaseURL = "https://api.livelox.com"
}
