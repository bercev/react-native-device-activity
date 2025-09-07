//
//  ShieldConfigurationExtension.swift
//  ShieldConfiguration
//
//  Created by Robert Herber on 2024-10-25.
//

import FamilyControls
import Foundation
import ManagedSettings
import ManagedSettingsUI
import UIKit
import os

import CryptoKit

fileprivate func stableAppKey(_ application: Application) -> String {
  if let bid = application.bundleIdentifier, !bid.isEmpty { return "app:\(bid)" }
  return "app:" + (application.token.map { stableTokenString($0) } ?? "unknown")
}

fileprivate func stableDomainKey(_ web: WebDomain) -> String {
  if let dom = web.domain?.lowercased(), !dom.isEmpty { return "domain:\(dom)" }
  if let tok = web.token {
    let s = String(describing: tok)
    let d = Data(s.utf8)
    let h = SHA256.hash(data: d).map { String(format: "%02x", $0) }.joined()
    return "domain:\(h)"
  }
  return "domain:unknown"
}

fileprivate func stableTokenString(_ token: Any) -> String {
  // Fallback: stringify then hash for compactness
  let s = String(describing: token)
  let data = Data(s.utf8)
  let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  return digest
}

// --- NEW small helpers (used by both app & domain counters) ---
fileprivate let debounceSeconds: TimeInterval = 2.0

fileprivate func todayKey() -> String {
  let df = DateFormatter()
  df.calendar = .init(identifier: .iso8601)
  df.locale   = .init(identifier: "en_US_POSIX")
  df.timeZone = .init(secondsFromGMT: 0)
  df.dateFormat = "yyyy-MM-dd"
  return df.string(from: Date())
}

fileprivate func countKey(_ appKey: String) -> String {
  "shield.opens.\(todayKey()).\(appKey)"
}

fileprivate func lastSeenKey(_ appKey: String) -> String {
  "shield.opens.lastSeen.\(appKey)"
}

// Read (string key)
fileprivate func currentOpenCount(appKey: String) -> Int {
  let defaults = UserDefaults(suiteName: appGroup)
  return defaults?.integer(forKey: countKey(appKey)) ?? 0
}

// Legacy Int-based READ (kept for compatibility) -> delegates to string key
fileprivate func currentOpenCount(_ tokenHash: Int) -> Int {
  currentOpenCount(appKey: "legacy:\(tokenHash)")
}

// Bump (string key) with debounce
fileprivate func bumpOpenCount(appKey: String) -> Int {
  let defaults = UserDefaults(suiteName: appGroup)
  let now  = Date().timeIntervalSince1970
  let last = defaults?.double(forKey: lastSeenKey(appKey)) ?? 0

  // Debounce: avoid double-increment for one presentation
  if now - last < debounceSeconds {
    return defaults?.integer(forKey: countKey(appKey)) ?? 0
  }

  let next = (defaults?.integer(forKey: countKey(appKey)) ?? 0) + 1
  defaults?.set(next, forKey: countKey(appKey))
  defaults?.set(now,  forKey: lastSeenKey(appKey))
  return next
}

// Legacy Int-based BUMP (kept for compatibility) -> delegates to string key
fileprivate func bumpOpenCount(_ tokenHash: Int) -> Int {
  bumpOpenCount(appKey: "legacy:\(tokenHash)")
}

// Legacy Int-based key (kept for compatibility) -> maps to string key
fileprivate func openCountKey(_ tokenHash: Int) -> String {
  countKey("legacy:\(tokenHash)")
}

// JS config loader (unchanged)
fileprivate func loadJSShieldConfig() -> [String: Any] {
  (UserDefaults(suiteName: appGroup)?.dictionary(forKey: "shield.config.v1")) ?? [:]
}

// Prefer per-app messages (by bundle id), else global; index safely from openCount
fileprivate func messageFromConfig(cfg: [String: Any], bundleId: String?, openCount: Int) -> String? {
  var messages: [String] = []
  if
    let bundleId,
    let perApp = cfg["perApp"] as? [String: Any],
    let appCfg = perApp[bundleId] as? [String: Any],
    let arr = appCfg["messages"] as? [String]
  {
    messages = arr
  } else if let arr = cfg["messages"] as? [String] {
    messages = arr
  }
  guard !messages.isEmpty else { return nil }
  let idx = max(openCount - 1, 0) % messages.count   // start from first message at count == 1
  return messages[idx]
}


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
    let msg = messageFromConfig(cfg: cfg, bundleId: bundleId, openCount: openCount) ?? "Come back to Retention and study!"


    var placeholders: [String: String?] = [
      "applicationOrDomainDisplayName": application.localizedDisplayName,
      "token": "\(tokenHash)",
      "tokenType": "application",
      "familyActivitySelectionId": getPossibleFamilyActivitySelectionIds(
        applicationToken: application.token
      ).first?.id,
      "shieldOpenCount": "\(openCount)",
      "shieldMessage": msg
    ]

    if let global = cfg["globalPlaceholders"] as? [String: String] {
      for (k, v) in global { placeholders[k] = v }
    }

    return buildShield(
      placeholders: placeholders,
      config: config
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
    let msg = messageFromConfig(cfg: cfg, bundleId: bundleId, openCount: max(openCount, 1))
            ?? "Come back to Retention and study!"

    let applicationTokenStr = application.token.map { stableTokenString($0) } // your helper
    let categoryTokenStr    = category.token.map { stableTokenString($0) }    // your helper

    var placeholders: [String: String?] = [
      "applicationOrDomainDisplayName": application.localizedDisplayName,
      "categoryDisplayName": category.localizedDisplayName,
      // expose BOTH; let templates pick one
      "applicationToken": applicationTokenStr,
      "categoryToken": categoryTokenStr,
      // keep a generic type for templates if you need it
      "tokenType": "application_category",
      "familyActivitySelectionId": getPossibleFamilyActivitySelectionIds(
        applicationToken: application.token,
        categoryToken: category.token
      ).first?.id,
      "shieldOpenCount": "\(openCount)",
      "shieldMessage": msg
    ]

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

    // Increment (debounced) per-domain
    let domKey    = stableDomainKey(webDomain)
    let openCount = bumpOpenCount(appKey: domKey)

    // JS-driven copy (perDomain['domain'] or global messages)
    let cfg = loadJSShieldConfig()
    let msg: String? = {
        if let perDomain = cfg["perDomain"] as? [String: Any],
        let domainKey = webDomain.domain?.lowercased(),                  // ✅ unwrap
        let domCfg = perDomain[domainKey] as? [String: Any],
        let arr = domCfg["messages"] as? [String], !arr.isEmpty {
        let idx = (max(openCount, 1) - 1) % arr.count                     // loop
        return arr[idx]
      }
      if let arr = cfg["messages"] as? [String], !arr.isEmpty {
        return arr[(max(openCount, 1) - 1) % arr.count]
      }
      return "Come back to Retention and study!"
    }()

    let webDomainTokenStr = webDomain.token.map { stableTokenString($0) }

    var placeholders: [String: String?] = [
      "applicationOrDomainDisplayName": webDomain.domain ?? "(Unknown site)",
      "domainDisplayName": webDomain.domain ?? "(Unknown site)",
      "token": webDomainTokenStr,         // generic token = domain by default
      "webDomainToken": webDomainTokenStr,
      "tokenType": "web_domain",
      "familyActivitySelectionId": getPossibleFamilyActivitySelectionIds(
        webDomainToken: webDomain.token
      ).first?.id,
      "shieldOpenCount": "\(openCount)",
      "shieldMessage": msg,
    ]

    if let global = cfg["globalPlaceholders"] as? [String: String] {
      for (k, v) in global { placeholders[k] = v }
    }

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

  
    let domKey    = stableDomainKey(webDomain)
    let openCount = bumpOpenCount(appKey: domKey)
  
    // JS-driven copy (perDomain['domain'] or global messages)
    let cfg = loadJSShieldConfig()
    let msg: String? = {
      if let perDomain = cfg["perDomain"] as? [String: Any],
      let domainKey = webDomain.domain?.lowercased(),                  // ✅ unwrap
      let domCfg = perDomain[domainKey] as? [String: Any],
      let arr = domCfg["messages"] as? [String], !arr.isEmpty {
      let idx = (max(openCount, 1) - 1) % arr.count                     // loop
      return arr[idx]
    }
      if let arr = cfg["messages"] as? [String], !arr.isEmpty {
        return arr[(max(openCount, 1) - 1) % arr.count]
      }
      return "Come back to Retention and study!"
    }()

    let webDomainTokenStr = webDomain.token.map { stableTokenString($0) }
    let categoryTokenStr  = category.token.map { stableTokenString($0) }

    var placeholders: [String: String?] = [
      "applicationOrDomainDisplayName": webDomain.domain ?? "(Unknown site)",
      "domainDisplayName": webDomain.domain ?? "(Unknown site)",
      "categoryDisplayName": category.localizedDisplayName,
      // keep generic {token} as category (matches your previous behavior)
      "token": categoryTokenStr,
      "webDomainToken": webDomainTokenStr,
      "categoryToken": categoryTokenStr,
      "tokenType": "web_domain_category",
      "familyActivitySelectionId": getPossibleFamilyActivitySelectionIds(
        webDomainToken: webDomain.token,
        categoryToken: category.token
      ).first?.id,
      "shieldOpenCount": "\(openCount)",
      "shieldMessage": msg,
    ]

    if let global = cfg["globalPlaceholders"] as? [String: String] {
      for (k, v) in global { placeholders[k] = v }
    }

    return buildShield(placeholders: placeholders, config: config)
  }
}
