import Foundation

public enum DisplayLocale {
    public static func english(from locale: Locale) -> Locale {
        var components = Locale.Components(locale: locale)
        components.languageComponents = Locale.Language.Components(
            languageCode: .english, script: nil, region: locale.region
        )
        components.numberingSystem = Locale.NumberingSystem("latn")
        components.hourCycle = locale.hourCycle
        return Locale(components: components)
    }
}
