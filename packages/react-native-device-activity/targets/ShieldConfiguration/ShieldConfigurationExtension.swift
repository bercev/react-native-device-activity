//
//  ShieldConfigurationExtension.swift
//  ShieldConfiguration
//
//  Created by Robert Herber on 2024-10-25.
//

import CryptoKit
import FamilyControls
import Foundation
import ManagedSettings
import ManagedSettingsUI
import UIKit
import os

// =========================================================
// These help with the webdomain configuration
private func webDomainMessage(cfg: [String: Any], webDomain: WebDomain, openCount: Int) -> String {
  if let perDomain = cfg["perDomain"] as? [String: Any],
    let key = webDomain.domain?.lowercased(),
    let domCfg = perDomain[key] as? [String: Any],
    let arr = domCfg["messages"] as? [String], !arr.isEmpty
  {
    let idx = (max(openCount, 1) - 1) % arr.count
    return arr[idx]
  }
  if let arr = cfg["messages"] as? [String], !arr.isEmpty {
    let idx = (max(openCount, 1) - 1) % arr.count
    return arr[idx]
  }
  return "Come back to Retention and study!"
}

private func webDomainPlaceholders(
  webDomain: WebDomain,
  category: ActivityCategory?,
  openCount: Int,
  cfg: [String: Any]
) -> [String: String?] {
  let webDomainTokenStr = webDomain.token.map { stableTokenString($0) }
  var placeholders: [String: String?] = [
    "applicationOrDomainDisplayName": webDomain.domain ?? "(Unknown site)",
    "domainDisplayName": webDomain.domain ?? "(Unknown site)",
    "webDomainToken": webDomainTokenStr,
    "tokenType": category == nil ? "web_domain" : "web_domain_category",
    "familyActivitySelectionId": getPossibleFamilyActivitySelectionIds(
      webDomainToken: webDomain.token, categoryToken: category?.token
    ).first?.id,
    "shieldOpenCount": "\(openCount)",
    "shieldMessage": webDomainMessage(cfg: cfg, webDomain: webDomain, openCount: openCount),
  ]
  if let category {
    let categoryTokenStr = category.token.map { stableTokenString($0) }
    placeholders["categoryDisplayName"] = category.localizedDisplayName
    placeholders["categoryToken"] = categoryTokenStr
    placeholders["token"] = categoryTokenStr  // keep your generic {token} as category here
  } else {
    placeholders["token"] = webDomainTokenStr  // generic {token} = domain for domain-only
  }
  if let global = cfg["globalPlaceholders"] as? [String: String] {
    for (k, v) in global { placeholders[k] = v }
  }
  return placeholders
}
// =========================================================

// =========================================================
// these help with separating shields so we dont run into issues with using the wrong shield for a particular selection
private func selectionConfig(cfg: [String: Any], selectionId: String?) -> [String: Any]? {
  guard let selectionId,
    let perSel = cfg["perSelectionId"] as? [String: Any],
    let sCfg = perSel[selectionId] as? [String: Any]
  else { return nil }
  return sCfg
}
// =========================================================

// =========================================================
// these help with the overall system of changing the shield message based on # times an app has been accessed while in a blocked stated
private func stableAppKey(_ application: Application) -> String {
  if let bid = application.bundleIdentifier, !bid.isEmpty { return "app:\(bid)" }
  return "app:" + (application.token.map { stableTokenString($0) } ?? "unknown")
}

private func stableDomainKey(_ web: WebDomain) -> String {
  if let dom = web.domain?.lowercased(), !dom.isEmpty { return "domain:\(dom)" }
  if let tok = web.token {
    let s = String(describing: tok)
    let d = Data(s.utf8)
    let h = SHA256.hash(data: d).map { String(format: "%02x", $0) }.joined()
    return "domain:\(h)"
  }
  return "domain:unknown"
}

private func stableTokenString(_ token: Any) -> String {
  // Fallback: stringify then hash for compactness
  let s = String(describing: token)
  let data = Data(s.utf8)
  let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  return digest
}

// --- NEW small helpers (used by both app & domain counters) ---
private let debounceSeconds: TimeInterval = 2.0

private func todayKey() -> String {
  let df = DateFormatter()
  df.calendar = .init(identifier: .iso8601)
  df.locale = .init(identifier: "en_US_POSIX")
  df.timeZone = .init(secondsFromGMT: 0)
  df.dateFormat = "yyyy-MM-dd"
  return df.string(from: Date())
}

private func countKey(_ appKey: String) -> String {
  "shield.opens.\(todayKey()).\(appKey)"
}

private func lastSeenKey(_ appKey: String) -> String {
  "shield.opens.lastSeen.\(appKey)"
}

// Read (string key)
private func currentOpenCount(appKey: String) -> Int {
  let defaults = UserDefaults(suiteName: appGroup)
  return defaults?.integer(forKey: countKey(appKey)) ?? 0
}

// Legacy Int-based READ (kept for compatibility) -> delegates to string key
private func currentOpenCount(_ tokenHash: Int) -> Int {
  currentOpenCount(appKey: "legacy:\(tokenHash)")
}

// Bump (string key) with debounce
private func bumpOpenCount(appKey: String) -> Int {
  let defaults = UserDefaults(suiteName: appGroup)
  let now = Date().timeIntervalSince1970
  let last = defaults?.double(forKey: lastSeenKey(appKey)) ?? 0

  // Debounce: avoid double-increment for one presentation
  if now - last < debounceSeconds {
    return defaults?.integer(forKey: countKey(appKey)) ?? 0
  }

  let next = (defaults?.integer(forKey: countKey(appKey)) ?? 0) + 1
  defaults?.set(next, forKey: countKey(appKey))
  defaults?.set(now, forKey: lastSeenKey(appKey))
  return next
}

// Legacy Int-based BUMP (kept for compatibility) -> delegates to string key
private func bumpOpenCount(_ tokenHash: Int) -> Int {
  bumpOpenCount(appKey: "legacy:\(tokenHash)")
}

// Legacy Int-based key (kept for compatibility) -> maps to string key
private func openCountKey(_ tokenHash: Int) -> String {
  countKey("legacy:\(tokenHash)")
}

// JS config loader (unchanged)
private func loadJSShieldConfig() -> [String: Any] {
  (UserDefaults(suiteName: appGroup)?.dictionary(forKey: "shield.config.v1")) ?? [:]
}

// Prefer per-selection messages, else per-app, else global
private func messageFromConfig(
  cfg: [String: Any],
  bundleId: String?,
  selectionId: String?,
  openCount: Int
) -> String? {
  // 1) per selection
  if let sCfg = selectionConfig(cfg: cfg, selectionId: selectionId),
    let arr = sCfg["messages"] as? [String], !arr.isEmpty
  {
    let idx = (max(openCount, 1) - 1) % arr.count
    return arr[idx]
  }
  // 2) per app
  if let bundleId,
    let perApp = cfg["perApp"] as? [String: Any],
    let appCfg = perApp[bundleId] as? [String: Any],
    let arr = appCfg["messages"] as? [String], !arr.isEmpty
  {
    let idx = (max(openCount, 1) - 1) % arr.count
    return arr[idx]
  }
  // 3) global
  if let arr = cfg["messages"] as? [String], !arr.isEmpty {
    let idx = (max(openCount, 1) - 1) % arr.count
    return arr[idx]
  }
  return nil
}

// =========================================================
// end of changes
// =========================================================

func convertBase64StringToImage(imageBase64String: String?) -> UIImage? {
  if let imageBase64String = imageBase64String {
    let imageData = Data(base64Encoded: imageBase64String)
    let image = UIImage(data: imageData!)
    return image
  }

  return nil
}

func buildLabel(text: String?, with color: UIColor?, placeholders: [String: String?])
  -> ShieldConfiguration.Label?
{
  if let text = text {
    let color = color ?? UIColor.label
    return .init(text: replacePlaceholders(text, with: placeholders), color: color)
  }

  return nil
}

func loadImageFromAppGroupDirectory(relativeFilePath: String) -> UIImage? {
  let appGroupDirectory = getAppGroupDirectory()

  let fileURL = appGroupDirectory!.appendingPathComponent(relativeFilePath)

  // Load the image data
  guard let imageData = try? Data(contentsOf: fileURL) else {
    print("Error: Could not load data from \(fileURL.path)")
    return nil
  }

  // Create and return the UIImage
  return UIImage(data: imageData)
}

func resolveIcon(dict: [String: Any]) -> UIImage? {
  let iconAppGroupRelativePath = dict["iconAppGroupRelativePath"] as? String
  let iconSystemName = dict["iconSystemName"] as? String

  var image: UIImage?

  if let iconSystemName = iconSystemName {
    image = UIImage(systemName: iconSystemName)
  }

  if let iconAppGroupRelativePath = iconAppGroupRelativePath {
    image = loadImageFromAppGroupDirectory(relativeFilePath: iconAppGroupRelativePath)
  }

  if let iconTint = getColor(color: dict["iconTint"] as? [String: Double]) {
    image?.withTintColor(iconTint)
  }

  return image
}

func buildShield(placeholders: [String: String?], config: [String: Any]?)
  -> ShieldConfiguration
{

  if let appGroup = appGroup {
    logger.log("Calling getShieldConfiguration with appgroup: \(appGroup, privacy: .public)")
  } else {
    logger.log("Calling getShieldConfiguration without appgroup!")
  }

  CFPreferencesAppSynchronize(kCFPreferencesCurrentApplication)

  if let config = config {
    let backgroundColor = getColor(color: config["backgroundColor"] as? [String: Double])

    let title = config["title"] as? String
    let titleColor = getColor(color: config["titleColor"] as? [String: Double])

    let subtitle = config["subtitle"] as? String
    let subtitleColor = getColor(color: config["subtitleColor"] as? [String: Double])

    let primaryButtonLabel = config["primaryButtonLabel"] as? String
    let primaryButtonLabelColor = getColor(
      color: config["primaryButtonLabelColor"] as? [String: Double])
    let primaryButtonBackgroundColor = getColor(
      color: config["primaryButtonBackgroundColor"] as? [String: Double])

    let secondaryButtonLabel = config["secondaryButtonLabel"] as? String
    let secondaryButtonLabelColor = getColor(
      color: config["secondaryButtonLabelColor"] as? [String: Double]
    )

    let shield = ShieldConfiguration(
      backgroundBlurStyle: config["backgroundBlurStyle"] != nil
        ? (config["backgroundBlurStyle"] as? Int).flatMap(UIBlurEffect.Style.init) : nil,
      backgroundColor: backgroundColor,
      icon: resolveIcon(dict: config),
      title: buildLabel(text: title, with: titleColor, placeholders: placeholders),
      subtitle: buildLabel(text: subtitle, with: subtitleColor, placeholders: placeholders),
      primaryButtonLabel: buildLabel(
        text: primaryButtonLabel, with: primaryButtonLabelColor, placeholders: placeholders),
      primaryButtonBackgroundColor: primaryButtonBackgroundColor,
      secondaryButtonLabel: buildLabel(
        text: secondaryButtonLabel, with: secondaryButtonLabelColor, placeholders: placeholders)
    )
    logger.log("shield initialized")

    return shield
  }

  return ShieldConfiguration()
}

// Override the functions below to customize the shields used in various situations.
// The system provides a default appearance for any methods that your subclass doesn't override.
// Make sure that your class name matches the NSExtensionPrincipalClass in your Info.plist.
class ShieldConfigurationExtension: ShieldConfigurationDataSource {
  override func configuration(shielding application: Application) -> ShieldConfiguration {
    // Customize the shield as needed for applications.
    logger.log("shielding application")
    let config = getActivitySelectionPrefixedConfigFromUserDefaults(
      keyPrefix: SHIELD_CONFIGURATION_FOR_SELECTION_PREFIX,
      fallbackKey: FALLBACK_SHIELD_CONFIGURATION_KEY,
      applicationToken: application.token
    )
    // !! showing a different shield each time
    let tokenHash = stableAppKey(application)
    let openCount = bumpOpenCount(appKey: tokenHash)
    let cfg = loadJSShieldConfig()
    var bundleId: String? = nil
    if let tok = application.token {
      // If `Application(token:).bundleIdentifier` isn’t available on your SDK, this stays nil.
      bundleId = Application(token: tok).bundleIdentifier
    }
    let selectionId = getPossibleFamilyActivitySelectionIds(applicationToken: application.token)
      .first?.id
    let msg =
      messageFromConfig(
        cfg: cfg, bundleId: bundleId, selectionId: selectionId, openCount: openCount)
      ?? "Come back to Retention and study!"

    var placeholders: [String: String?] = [
      "applicationOrDomainDisplayName": application.localizedDisplayName,
      "token": "\(tokenHash)",
      "tokenType": "application",
      "familyActivitySelectionId": selectionId,
      "shieldOpenCount": "\(openCount)",
      "shieldMessage": msg,
    ]

    if let global = cfg["globalPlaceholders"] as? [String: String] {
      for (k, v) in global { placeholders[k] = v }
    }

    return buildShield(
      placeholders: placeholders,
      config: config  // use the scoped config if its available, else default to original
    )
  }

  override func configuration(shielding application: Application, in category: ActivityCategory)
    -> ShieldConfiguration
  {
    logger.log("shielding application category")
    let config = getActivitySelectionPrefixedConfigFromUserDefaults(
      keyPrefix: SHIELD_CONFIGURATION_FOR_SELECTION_PREFIX,
      fallbackKey: FALLBACK_SHIELD_CONFIGURATION_KEY,
      applicationToken: application.token,
      categoryToken: category.token
    )

    let tokenHash = stableAppKey(application)
    let openCount = bumpOpenCount(appKey: tokenHash)
    let cfg = loadJSShieldConfig()
    var bundleId: String? = nil
    if let tok = application.token {
      // If `Application(token:).bundleIdentifier` isn’t available on your SDK, this stays nil.
      bundleId = Application(token: tok).bundleIdentifier
    }

    let selectionId = getPossibleFamilyActivitySelectionIds(
      applicationToken: application.token,
      categoryToken: category.token
    ).first?.id
    let msg =
      messageFromConfig(
        cfg: cfg, bundleId: bundleId, selectionId: selectionId, openCount: max(openCount, 1))
      ?? "Come back to Retention and study!"

    let applicationTokenStr = application.token.map { stableTokenString($0) }  // your helper
    let categoryTokenStr = category.token.map { stableTokenString($0) }  // your helper
    var placeholders: [String: String?] = [
      "applicationOrDomainDisplayName": application.localizedDisplayName,
      "categoryDisplayName": category.localizedDisplayName,
      // expose BOTH; let templates pick one
      "applicationToken": applicationTokenStr,
      "categoryToken": categoryTokenStr,
      // keep a generic type for templates if you need it
      "tokenType": "application_category",
      "familyActivitySelectionId": selectionId,
      "shieldOpenCount": "\(openCount)",
      "shieldMessage": msg,
    ]

    if let global = cfg["globalPlaceholders"] as? [String: String] {
      for (k, v) in global { placeholders[k] = v }
    }

    return buildShield(
      placeholders: placeholders,
      config: config
    )
  }

  override func configuration(shielding webDomain: WebDomain) -> ShieldConfiguration {
    logger.log("shielding web domain")

    let config = getActivitySelectionPrefixedConfigFromUserDefaults(
      keyPrefix: SHIELD_CONFIGURATION_FOR_SELECTION_PREFIX,
      fallbackKey: FALLBACK_SHIELD_CONFIGURATION_KEY,
      webDomainToken: webDomain.token
    )
    let domKey = stableDomainKey(webDomain)
    let openCount = bumpOpenCount(appKey: domKey)
    let cfg = loadJSShieldConfig()
    let placeholders = webDomainPlaceholders(
      webDomain: webDomain, category: nil, openCount: openCount, cfg: cfg)
    return buildShield(placeholders: placeholders, config: config)
  }

  override func configuration(shielding webDomain: WebDomain, in category: ActivityCategory)
    -> ShieldConfiguration
  {
    logger.log("shielding web domain category")
    let config = getActivitySelectionPrefixedConfigFromUserDefaults(
      keyPrefix: SHIELD_CONFIGURATION_FOR_SELECTION_PREFIX,
      fallbackKey: FALLBACK_SHIELD_CONFIGURATION_KEY,
      webDomainToken: webDomain.token,
      categoryToken: category.token
    )
    let domKey = stableDomainKey(webDomain)
    let openCount = bumpOpenCount(appKey: domKey)
    let cfg = loadJSShieldConfig()
    let placeholders = webDomainPlaceholders(
      webDomain: webDomain, category: category, openCount: openCount, cfg: cfg)
    return buildShield(placeholders: placeholders, config: config)
  }
}
