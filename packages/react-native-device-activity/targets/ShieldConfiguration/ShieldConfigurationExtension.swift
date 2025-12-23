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


// Logic to help with choosing specific messages

// MARK: - Message array helpers

private func _readBool(_ obj: Any?, default defaultValue: Bool) -> Bool {
  if let b = obj as? Bool { return b }
  if let n = obj as? NSNumber { return n.boolValue }
  if let s = obj as? String {
    let v = s.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
    if v == "true" || v == "1" { return true }
    if v == "false" || v == "0" { return false }
  }
  return defaultValue
}

private func _pickIndex(openCount: Int, arrayCount: Int, loop: Bool) -> Int {
  guard arrayCount > 0 else { return 0 }
  let i = max(openCount - 1, 0)
  if loop {
    return i % arrayCount
  } else {
    return min(i, arrayCount - 1)
  }
}

private func _pickMessage(_ arrAny: Any?, openCount: Int, loop: Bool) -> String? {
  guard let arr = arrAny as? [String], !arr.isEmpty else { return nil }
  let idx = _pickIndex(openCount: openCount, arrayCount: arr.count, loop: loop)
  return arr[idx]
}




// MARK: - Icon choice helpers

private func _trimLeadingSlash(_ s: String) -> String {
  var v = s
  while v.hasPrefix("/") { v.removeFirst() }
  return v
}

// Convert a single icon choice object into the existing config keys that `resolveIcon(dict:)` supports.
// Expected format: { "type": "SFSymbol" | "AppGroupRelativePath" | "AssetName", "name": "<string>" }
private func _iconDictFromChoice(_ choiceAny: Any?) -> [String: Any]? {
  guard let choice = choiceAny as? [String: Any] else { return nil }
  guard let type = choice["type"] as? String,
        let rawName = choice["name"] as? String else { return nil }

  let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
  if name.isEmpty { return nil }

  switch type {
  case "SFSymbol":
    return ["iconSystemName": name]
  case "AppGroupRelativePath":
    return ["iconAppGroupRelativePath": _trimLeadingSlash(name)]
  case "AssetName":
    return ["iconAssetName": name]
  default:
    return nil
  }
}

private func _pickIconOverride(
  scoped: [String: Any],
  root: [String: Any],
  openCount: Int
) -> [String: Any]? {
  guard let choices = scoped["iconChoices"] as? [Any], !choices.isEmpty else { return nil }
  let loop = _readBool(scoped["loopIcons"], default: _readBool(root["loopIcons"], default: true))
  let idx = _pickIndex(openCount: openCount, arrayCount: choices.count, loop: loop)
  return _iconDictFromChoice(choices[idx])
}

private func _mergeConfig(_ base: [String: Any]?, override: [String: Any]?) -> [String: Any]? {
  guard let override = override, !override.isEmpty else { return base }
  var out = base ?? [:]
  for (k, v) in override { out[k] = v }
  return out
}
// ================================
// These help with getting a specific shield configuration based on selectionid
private func selectionIdFor(
  applicationToken: ApplicationToken? = nil,
  webDomainToken: WebDomainToken? = nil,
  categoryToken: ActivityCategoryToken? = nil
) -> String? {
  // Ask the same resolver that getActivitySelectionPrefixedConfigFromUserDefaults uses
  if let key = tryGetActivitySelectionIdConfigKey(
        keyPrefix: SHIELD_CONFIGURATION_FOR_SELECTION_PREFIX,
        applicationToken: applicationToken,
        webDomainToken: webDomainToken,
        categoryToken: categoryToken
      ) {
    let prefix = SHIELD_CONFIGURATION_FOR_SELECTION_PREFIX + "_"
    return key.hasPrefix(prefix) ? String(key.dropFirst(prefix.count)) : nil
  }
  return nil
}

// =========================================================
// These help with the webdomain configuration
private func webDomainMessage(cfg: [String: Any], webDomain: WebDomain, openCount: Int) -> String {
  // 1) per-domain
  if let perDomain = cfg["perDomain"] as? [String: Any],
     let key = webDomain.domain?.lowercased(),
     let domCfg = perDomain[key] as? [String: Any],
     let arr = domCfg["messages"] as? [String],
     !arr.isEmpty
  {
    let loop = _readBool(domCfg["loopMessages"], default: _readBool(cfg["loopMessages"], default: true))
    let idx = _pickIndex(openCount: openCount, arrayCount: arr.count, loop: loop)
    return arr[idx]
  }

  // 2) global
  if let arr = cfg["messages"] as? [String], !arr.isEmpty {
    let loop = _readBool(cfg["loopMessages"], default: true)
    let idx = _pickIndex(openCount: openCount, arrayCount: arr.count, loop: loop)
    return arr[idx]
  }

  // 3) fallback
  return "Come back to Retention and study!"
}


private func webDomainPlaceholders(
  webDomain: WebDomain,
  category: ActivityCategory?,
  openCount: Int,
  cfg: [String: Any]
) -> [String: String?] {

  let domainKey = webDomain.domain?.lowercased()
  let perDomain = cfg["perDomain"] as? [String: Any]
  let domCfg = (domainKey != nil ? (perDomain?[domainKey!] as? [String: Any]) : nil) ?? cfg

  let loop = _readBool(domCfg["loopMessages"], default: _readBool(cfg["loopMessages"], default: true))
  let shieldMsg = _pickMessage(domCfg["messages"], openCount: openCount, loop: loop) ?? "Come back to Retention and study!"
  let titleMsg = _pickMessage(domCfg["titleMessages"], openCount: openCount, loop: loop)
  let subtitleMsg = _pickMessage(domCfg["subtitleMessages"], openCount: openCount, loop: loop)

  let webDomainTokenStr = webDomain.token.map { stableTokenString($0) }
  var placeholders: [String: String?] = [
    "applicationOrDomainDisplayName": webDomain.domain ?? "(Unknown site)",
    "domainDisplayName": webDomain.domain ?? "(Unknown site)",
    "webDomainToken": webDomainTokenStr,
    "tokenType": category == nil ? "web_domain" : "web_domain_category",
    "familyActivitySelectionId": selectionIdFor(webDomainToken: webDomain.token, categoryToken: category?.token) ?? getPossibleFamilyActivitySelectionIds(
      webDomainToken: webDomain.token,
      categoryToken: category?.token
    ).first?.id,
    "shieldOpenCount": "\(openCount)",
    "shieldMessage": shieldMsg,
    "shieldTitleMessage": titleMsg,
    "shieldSubtitleMessage": subtitleMsg,
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

// multiple messages and arrays
private func messagesFromConfig(
  cfg: [String: Any],
  bundleId: String?,
  selectionId: String?,
  openCount: Int
) -> (shield: String?, title: String?, subtitle: String?) {

  // Helper to compute loop + pick from a specific scoped dict
  func pick(from scoped: [String: Any]) -> (String?, String?, String?) {
    let loop = _readBool(scoped["loopMessages"], default: _readBool(cfg["loopMessages"], default: true))
    let shield = _pickMessage(scoped["messages"], openCount: openCount, loop: loop)
    let title = _pickMessage(scoped["titleMessages"], openCount: openCount, loop: loop)
    let subtitle = _pickMessage(scoped["subtitleMessages"], openCount: openCount, loop: loop)
    return (shield, title, subtitle)
  }

  // 1) per selection
  if let sCfg = selectionConfig(cfg: cfg, selectionId: selectionId) {
    let v = pick(from: sCfg)
    if v.0 != nil || v.1 != nil || v.2 != nil { return v }
  }

  // 2) per app
  if let bundleId,
     let perApp = cfg["perApp"] as? [String: Any],
     let appCfg = perApp[bundleId] as? [String: Any] {
    let v = pick(from: appCfg)
    if v.0 != nil || v.1 != nil || v.2 != nil { return v }
  }

  // 3) global root
  return pick(from: cfg)
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
  let iconAssetName = dict["iconAssetName"] as? String

  if let iconSystemName = iconSystemName {
    image = UIImage(systemName: iconSystemName)
  }

  if let iconAppGroupRelativePath = iconAppGroupRelativePath {
    image = loadImageFromAppGroupDirectory(relativeFilePath: iconAppGroupRelativePath)
  }

  if let iconTint = getColor(color: dict["iconTint"] as? [String: Double]) {
    image = image?.withTintColor(iconTint, renderingMode: .alwaysOriginal)
  }

  if let iconAssetName = iconAssetName {
    image = UIImage(named: iconAssetName)
  }

  if image == nil {
    image = UIImage(systemName: "hourglass")
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

  // MARK: - Modularized shield configuration

  private func iconOverrideForApplication(cfg: [String: Any], bundleId: String?, selectionId: String?, openCount: Int) -> [String: Any]? {
    // 1) per selection
    if let sCfg = selectionConfig(cfg: cfg, selectionId: selectionId),
       let picked = _pickIconOverride(scoped: sCfg, root: cfg, openCount: openCount) {
      return picked
    }
    // 2) per app
    if let bundleId,
       let perApp = cfg["perApp"] as? [String: Any],
       let appCfg = perApp[bundleId] as? [String: Any],
       let picked = _pickIconOverride(scoped: appCfg, root: cfg, openCount: openCount) {
      return picked
    }
    // 3) global
    return _pickIconOverride(scoped: cfg, root: cfg, openCount: openCount)
  }

  private func iconOverrideForWebDomain(cfg: [String: Any], webDomain: WebDomain, openCount: Int) -> [String: Any]? {
    // Same precedence as your web-domain message logic:
    // 1) per-domain, else 2) global root
    if let perDomain = cfg["perDomain"] as? [String: Any],
       let key = webDomain.domain?.lowercased(),
       let domCfg = perDomain[key] as? [String: Any],
       let picked = _pickIconOverride(scoped: domCfg, root: cfg, openCount: openCount) {
      return picked
    }
    return _pickIconOverride(scoped: cfg, root: cfg, openCount: openCount)
  }

  private func configurationForApplication(_ application: Application, category: ActivityCategory?) -> ShieldConfiguration {
    logger.log("shielding application")

    let nativeConfig = getActivitySelectionPrefixedConfigFromUserDefaults(
      keyPrefix: SHIELD_CONFIGURATION_FOR_SELECTION_PREFIX,
      fallbackKey: FALLBACK_SHIELD_CONFIGURATION_KEY,
      applicationToken: application.token,
      categoryToken: category?.token
    )

    // openCount (drives both message + icon rotation)
    let tokenHash = stableAppKey(application)
    let openCount = bumpOpenCount(appKey: tokenHash)

    // JS config (messages, placeholders, and now iconChoices)
    let cfg = loadJSShieldConfig()

    // bundleId (for perApp)
    var bundleId: String? = nil
    if let tok = application.token {
      bundleId = Application(token: tok).bundleIdentifier
    }

    // selectionId (for perSelectionId)
    let selectionId =
      selectionIdFor(applicationToken: application.token, categoryToken: category?.token)
      ?? getPossibleFamilyActivitySelectionIds(applicationToken: application.token, categoryToken: category?.token).first?.id

    // Messages (shieldMessage + optional title/subtitle message arrays)
    let picked = messagesFromConfig(cfg: cfg, bundleId: bundleId, selectionId: selectionId, openCount: openCount)
    let shieldMsg = picked.shield ?? "Come back to Retention and study!"

    // Placeholders
    let applicationTokenStr = application.token.map { stableTokenString($0) }
    var placeholders: [String: String?] = [
      "applicationOrDomainDisplayName": application.localizedDisplayName,
      "tokenType": category == nil ? "application" : "application_category",
      "familyActivitySelectionId": selectionId,
      "shieldOpenCount": "\(openCount)",
      "shieldMessage": shieldMsg,
      "shieldTitleMessage": picked.title,
      "shieldSubtitleMessage": picked.subtitle,
    ]

    if let category {
      let categoryTokenStr = category.token.map { stableTokenString($0) }
      placeholders["categoryDisplayName"] = category.localizedDisplayName
      placeholders["applicationToken"] = applicationTokenStr
      placeholders["categoryToken"] = categoryTokenStr
      placeholders["token"] = categoryTokenStr // keep your generic {token} as category here
    } else {
      placeholders["token"] = "\(tokenHash)"
      placeholders["applicationToken"] = applicationTokenStr
    }

    if let global = cfg["globalPlaceholders"] as? [String: String] {
      for (k, v) in global { placeholders[k] = v }
    }

    // Icon override (iconChoices) -> overlay into the native config, without changing buildShield/resolveIcon.
    let iconOverride = iconOverrideForApplication(cfg: cfg, bundleId: bundleId, selectionId: selectionId, openCount: openCount)
    let mergedConfig = _mergeConfig(nativeConfig, override: iconOverride)

    return buildShield(placeholders: placeholders, config: mergedConfig)
  }

  private func configurationForWebDomain(_ webDomain: WebDomain, category: ActivityCategory?) -> ShieldConfiguration {
    logger.log("shielding web domain")

    let nativeConfig = getActivitySelectionPrefixedConfigFromUserDefaults(
      keyPrefix: SHIELD_CONFIGURATION_FOR_SELECTION_PREFIX,
      fallbackKey: FALLBACK_SHIELD_CONFIGURATION_KEY,
      webDomainToken: webDomain.token,
      categoryToken: category?.token
    )

    let domKey = stableDomainKey(webDomain)
    let openCount = bumpOpenCount(appKey: domKey)

    let cfg = loadJSShieldConfig()
    let placeholders = webDomainPlaceholders(
      webDomain: webDomain,
      category: category,
      openCount: openCount,
      cfg: cfg
    )

    let iconOverride = iconOverrideForWebDomain(cfg: cfg, webDomain: webDomain, openCount: openCount)
    let mergedConfig = _mergeConfig(nativeConfig, override: iconOverride)

    return buildShield(placeholders: placeholders, config: mergedConfig)
  }

  // MARK: - System overrides

  override func configuration(shielding application: Application) -> ShieldConfiguration {
    return configurationForApplication(application, category: nil)
  }

  override func configuration(shielding application: Application, in category: ActivityCategory) -> ShieldConfiguration {
    return configurationForApplication(application, category: category)
  }

  override func configuration(shielding webDomain: WebDomain) -> ShieldConfiguration {
    return configurationForWebDomain(webDomain, category: nil)
  }

  override func configuration(shielding webDomain: WebDomain, in category: ActivityCategory) -> ShieldConfiguration {
    return configurationForWebDomain(webDomain, category: category)
  }
}
