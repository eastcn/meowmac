import Foundation
import MeowMacCore

@MainActor
public enum CatRuntime {
    @discardableResult
    public static func initialize(state: PanelState, store: CatStore, layoutStore: PanelLayoutStore? = nil,
                                  environment: [String: String] = ProcessInfo.processInfo.environment) -> LoadedCat? {
        state.catStore = store
        state.layoutStore = layoutStore ?? PanelLayoutStore(rootURL: store.rootURL)
        state.selectedCat = store.loadSelection()
        state.loadLayoutForSelectedCat()
        state.initializeReminders(store: ReminderStore(rootURL: store.rootURL))
        switch environment["MEOWMAC_FORCE_LEVEL"] {
        case "normal": state.catLevelOverride = .normal
        case "warn": state.catLevelOverride = .warn
        case "severe": state.catLevelOverride = .severe
        default: state.catLevelOverride = nil
        }
        return state.selectedCat
    }
}
