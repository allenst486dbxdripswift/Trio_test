//
//  CareSensAirCGMManager.swift
//  Trio
//
//  Registers the CareSens Air (i-SENS) CGM as a CGMManagerUI in the Trio app target.
//  Persists the per-device serial + PIN, drives the BLE manager, and feeds glucose
//  (with trend) into Trio. Registered in BasePluginManager.cgms.
//
//  Trio hosts the setup/settings view controllers in a SwiftUI sheet with no
//  navigation bar, so those screens use in-content Cancel/Done buttons and
//  dismiss by notifying the completion delegate.
//

import Foundation
import HealthKit
import LoopKit
import LoopKitUI
import UIKit

public final class CareSensAirCGMManager: NSObject, CGMManagerUI {

    // MARK: - Persisted configuration

    /// 12-char sensor serial (e.g. "C1QBT5A01157").
    public private(set) var serial: String
    /// Box PIN code (used for BLE bonding; iOS presents the pairing dialog).
    public private(set) var pin: String
    private var isFirstConnection: Bool

    private var peripheralManager: CareSensAirPeripheralManager?

    // Trend tracking
    private var lastGlucoseValue: Int?
    private var lastGlucoseDate: Date?
    private var latestTrendRate: Double?   // mg/dL/min

    // MARK: - Delegate

    public var cgmManagerDelegate: CGMManagerDelegate? {
        get { delegate.delegate }
        set { delegate.delegate = newValue }
    }
    public var delegateQueue: DispatchQueue! {
        get { delegate.queue }
        set { delegate.queue = newValue }
    }
    private let delegate = WeakSynchronizedDelegate<CGMManagerDelegate>()

    // MARK: - DeviceManager

    public static let pluginIdentifier = "CareSensAirCGMManager"
    public static let localizedTitle = "CareSens Air"

    public var pluginIdentifier: String { Self.pluginIdentifier }
    public var managerIdentifier: String { Self.pluginIdentifier }
    public var localizedTitle: String { Self.localizedTitle }
    public let isOnboarded = true
    public var appURL: URL? { nil }
    public var device: HKDevice? {
        HKDevice(name: "CareSens Air", manufacturer: "i-SENS", model: "CSAir",
                 hardwareVersion: nil, firmwareVersion: nil, softwareVersion: nil,
                 localIdentifier: serial, udiDeviceIdentifier: nil)
    }

    // MARK: - CGMManager

    public var cgmManagerStatus: CGMManagerStatus {
        CGMManagerStatus(hasValidSensorSession: true, device: device)
    }
    public var shouldSyncToRemoteService = true
    public var providesBLEHeartbeat = false
    public var managedDataInterval: TimeInterval? = nil
    public var glucoseDisplay: GlucoseDisplayable? { nil }
    public override var debugDescription: String {
        "CareSensAirCGMManager(serial: \(serial), running: \(peripheralManager?.state.rawValue ?? "nil"))"
    }

    // MARK: - RawState

    public var rawState: CGMManager.RawStateValue {
        ["serial": serial, "pin": pin, "isFirstConnection": isFirstConnection]
    }

    public required init?(rawState: CGMManager.RawStateValue) {
        guard let serial = rawState["serial"] as? String, !serial.isEmpty else { return nil }
        self.serial = serial
        self.pin = (rawState["pin"] as? String) ?? ""
        self.isFirstConnection = (rawState["isFirstConnection"] as? Bool) ?? true
        super.init()
        startIfNeeded()
    }

    public init(serial: String, pin: String) {
        self.serial = serial
        self.pin = pin
        self.isFirstConnection = true
        super.init()
        startIfNeeded()
    }

    // MARK: - Lifecycle

    public func fetchNewDataIfNeeded(_ completion: @escaping (CGMReadingResult) -> Void) {
        // BLE stream is push-based; nothing to poll.
        completion(.noData)
    }

    private func startIfNeeded() {
        guard peripheralManager == nil else { return }
        let manager = CareSensAirPeripheralManager(serial: serial, isFirstConnection: isFirstConnection)
        manager.delegate = self
        peripheralManager = manager
        manager.start()
    }

    // MARK: - AlertResponder / AlertSoundVendor

    public func acknowledgeAlert(alertIdentifier: Alert.AlertIdentifier, completion: @escaping (Error?) -> Void) {
        completion(nil)
    }
    public func getSoundBaseURL() -> URL? { nil }
    public func getSounds() -> [Alert.Sound] { [] }

    // MARK: - CGMManagerUI

    public var cgmStatusHighlight: DeviceStatusHighlight? { nil }
    public var cgmLifecycleProgress: DeviceLifecycleProgress? { nil }
    public var cgmStatusBadge: DeviceStatusBadge? { nil }
    public static var onboardingImage: UIImage? { UIImage(named: "CareSens") }
    public var smallImage: UIImage? { UIImage(named: "CareSens") }

    // MARK: - Status exposed to the settings UI

    /// User-facing connection state text derived from the BLE manager.
    public var connectionStatusText: String {
        switch peripheralManager?.state {
        case .some(.running):      return "Connected"
        case .some(.handshaking):  return "Authenticating…"
        case .some(.connecting):   return "Connecting…"
        case .some(.scanning):     return "Searching for sensor…"
        case .some(.bluetoothOff): return "Bluetooth is off"
        case .some(.disconnected), .none: return "Disconnected"
        }
    }
    /// True once the sensor is fully connected and streaming.
    public var isConnected: Bool { peripheralManager?.state == .running }
    /// Most recent glucose value (mg/dL) and its timestamp, for the settings screen.
    public private(set) var latestGlucose: Int?
    public private(set) var latestGlucoseAt: Date?
    /// Called on the main queue whenever the connection state or glucose changes.
    public var statusDidChange: (() -> Void)?

    private func notifyStatusChanged() {
        DispatchQueue.main.async { [weak self] in self?.statusDidChange?() }
    }

    public static func setupViewController(bluetoothProvider: BluetoothProvider,
                                           displayGlucosePreference: DisplayGlucosePreference,
                                           colorPalette: LoopUIColorPalette,
                                           allowDebugFeatures: Bool,
                                           prefersToSkipUserInteraction: Bool) -> SetupUIResult<CGMManagerViewController, CGMManagerUI> {
        let vc = CareSensAirSetupViewController()
        return .userInteractionRequired(vc)
    }

    public func settingsViewController(bluetoothProvider: BluetoothProvider,
                                       displayGlucosePreference: DisplayGlucosePreference,
                                       colorPalette: LoopUIColorPalette,
                                       allowDebugFeatures: Bool) -> CGMManagerViewController {
        CareSensAirSettingsViewController(manager: self)
    }
}

// MARK: - CGMManager start/stop (LoopKit)

extension CareSensAirCGMManager {
    public func start() { startIfNeeded() }
    public func stop() {
        peripheralManager?.stop()
        peripheralManager = nil
    }

    /// Tears down BLE and asks Loop to remove this CGM manager.
    public func requestDeletion() {
        stop()
        delegate.notify { $0?.cgmManagerWantsDeletion(self) }
    }
}

// MARK: - CareSensAirPeripheralManagerDelegate

extension CareSensAirCGMManager: CareSensAirPeripheralManagerDelegate {

    func peripheralManager(_ manager: CareSensAirPeripheralManager, didReceive record: CareSensAirProtocol.GlucoseRecord) {
        guard let mgdl = record.currentGlucose else { return }
        let date = record.measurementTime

        // Compute trend rate (mg/dL/min) from the previous reading.
        var trend: GlucoseTrend? = nil
        var trendRate: HKQuantity? = nil
        if let prev = lastGlucoseValue, let prevDate = lastGlucoseDate {
            let minutes = date.timeIntervalSince(prevDate) / 60.0
            if minutes > 0.5 {
                let rate = Double(mgdl - prev) / minutes
                latestTrendRate = rate
                trend = Self.trend(forRate: rate)
                trendRate = HKQuantity(unit: HKUnit.milligramsPerDeciliter.unitDivided(by: .minute()), doubleValue: rate)
            }
        }
        lastGlucoseValue = mgdl
        lastGlucoseDate = date
        latestGlucose = mgdl
        latestGlucoseAt = date
        notifyStatusChanged()

        let sample = NewGlucoseSample(
            date: date,
            quantity: HKQuantity(unit: .milligramsPerDeciliter, doubleValue: Double(mgdl)),
            condition: nil,
            trend: trend,
            trendRate: trendRate,
            isDisplayOnly: false,
            wasUserEntered: false,
            syncIdentifier: "\(serial)-\(record.sequence)-\(Int(date.timeIntervalSince1970))",
            device: device
        )
        delegate.notify { $0?.cgmManager(self, hasNew: .newData([sample])) }
    }

    func peripheralManager(_ manager: CareSensAirPeripheralManager, didChangeState state: CareSensAirPeripheralManager.State) {
        if state == .running { isFirstConnection = false }
        notifyStatusChanged()
        delegate.notify { $0?.cgmManagerDidUpdateState(self) }
    }

    func peripheralManager(_ manager: CareSensAirPeripheralManager, didError message: String) {
        // Surfaced via logs; Loop treats missing data as stale automatically.
    }

    private static func trend(forRate rate: Double) -> GlucoseTrend {
        switch rate {
        case let r where r > 3:   return .upUpUp
        case let r where r > 2:   return .upUp
        case let r where r > 1:   return .up
        case let r where r >= -1: return .flat
        case let r where r >= -2: return .down
        case let r where r >= -3: return .downDown
        default:                  return .downDownDown
        }
    }
}

// MARK: - Shared UI helpers

private enum CareSensUI {
    static let sensorImageSize: CGFloat = 132

    static func sensorImageView(height: CGFloat) -> UIImageView {
        let iv = UIImageView(image: UIImage(named: "CareSens"))
        iv.contentMode = .scaleAspectFit
        iv.heightAnchor.constraint(equalToConstant: height).isActive = true
        return iv
    }

    static func caption(_ text: String) -> UILabel {
        let l = UILabel()
        l.text = text.uppercased()
        l.font = .preferredFont(forTextStyle: .caption1)
        l.adjustsFontForContentSizeCategory = true
        l.textColor = .secondaryLabel
        return l
    }
}

// MARK: - Setup UI (enter the 4-digit device number + PIN)

public final class CareSensAirSetupViewController: UIViewController, CGMManagerOnboarding, CompletionNotifying {
    public weak var cgmManagerOnboardingDelegate: CGMManagerOnboardingDelegate?
    public weak var completionDelegate: CompletionDelegate?

    private let suffixField = UITextField()
    private let pinField = UITextField()

    public override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        title = "CareSens Air"

        let imageView = CareSensUI.sensorImageView(height: CareSensUI.sensorImageSize)

        let heading = UILabel()
        heading.text = "Add CareSens Air"
        heading.font = .preferredFont(forTextStyle: .title2)
        heading.adjustsFontForContentSizeCategory = true
        heading.textAlignment = .center

        let subtitle = UILabel()
        subtitle.text = "Enter the 4-digit number shown in the sensor's Bluetooth name (for example “CSair 1157” → 1157) and the PIN printed on the sensor box."
        subtitle.numberOfLines = 0
        subtitle.font = .preferredFont(forTextStyle: .subheadline)
        subtitle.adjustsFontForContentSizeCategory = true
        subtitle.textColor = .secondaryLabel
        subtitle.textAlignment = .center

        // Serial row: fixed prefix label + editable 4-digit suffix.
        let prefixLabel = UILabel()
        prefixLabel.text = CareSensAirProtocol.serialPrefix
        prefixLabel.font = .monospacedSystemFont(ofSize: 20, weight: .semibold)
        prefixLabel.textColor = .secondaryLabel
        prefixLabel.setContentHuggingPriority(.required, for: .horizontal)
        prefixLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        configure(suffixField, placeholder: "1157", keyboard: .numberPad)
        suffixField.font = .monospacedSystemFont(ofSize: 20, weight: .semibold)

        let serialRow = UIStackView(arrangedSubviews: [prefixLabel, suffixField])
        serialRow.axis = .horizontal
        serialRow.spacing = 6
        serialRow.alignment = .center

        configure(pinField, placeholder: "446732", keyboard: .numberPad)

        let continueButton = UIButton(type: .system)
        continueButton.setTitle("Continue", for: .normal)
        continueButton.titleLabel?.font = .preferredFont(forTextStyle: .headline)
        continueButton.setTitleColor(.white, for: .normal)
        continueButton.backgroundColor = .systemBlue
        continueButton.layer.cornerRadius = 12
        continueButton.heightAnchor.constraint(equalToConstant: 52).isActive = true
        continueButton.addTarget(self, action: #selector(done), for: .touchUpInside)

        // Trio hosts this VC in a sheet with no navigation bar, so Cancel must be
        // an in-content control.
        let cancelButton = UIButton(type: .system)
        cancelButton.setTitle("Cancel", for: .normal)
        cancelButton.titleLabel?.font = .preferredFont(forTextStyle: .body)
        cancelButton.addTarget(self, action: #selector(cancel), for: .touchUpInside)

        let stack = UIStackView(arrangedSubviews: [
            imageView, heading, subtitle,
            CareSensUI.caption("Device number"), serialRow,
            CareSensUI.caption("PIN code"), pinField,
            continueButton, cancelButton,
        ])
        stack.axis = .vertical
        stack.spacing = 10
        stack.setCustomSpacing(20, after: subtitle)
        stack.setCustomSpacing(20, after: serialRow)
        stack.setCustomSpacing(24, after: pinField)
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 20),
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24),
        ])
    }

    private func configure(_ field: UITextField, placeholder: String, keyboard: UIKeyboardType = .default) {
        field.placeholder = placeholder
        field.borderStyle = .roundedRect
        field.keyboardType = keyboard
        field.autocapitalizationType = .none
        field.autocorrectionType = .no
    }

    private func showAlert(_ title: String, _ message: String) {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        present(alert, animated: true)
    }

    @objc private func done() {
        view.endEditing(true)
        let last4 = (suffixField.text ?? "").trimmingCharacters(in: .whitespaces)
        guard let serial = CareSensAirProtocol.serial(fromLast4: last4) else {
            showAlert("Check the device number", "Enter the 4 digits from the sensor's Bluetooth name — for example, 1157.")
            return
        }
        let pin = (pinField.text ?? "").trimmingCharacters(in: .whitespaces)
        guard pin.count >= 4 else {
            showAlert("Check the PIN", "Enter the PIN printed on the sensor box — for example, 446732.")
            return
        }
        let manager = CareSensAirCGMManager(serial: serial, pin: pin)
        cgmManagerOnboardingDelegate?.cgmManagerOnboarding(didCreateCGMManager: manager)
        cgmManagerOnboardingDelegate?.cgmManagerOnboarding(didOnboardCGMManager: manager)
        complete()
    }

    @objc private func cancel() {
        complete()
    }

    /// Trio hosts this VC in a SwiftUI sheet and closes it when the completion
    /// delegate fires (it sets `shouldDisplayCGMSetupSheet = false`), so simply
    /// notifying the delegate is enough to dismiss.
    private func complete() {
        completionDelegate?.completionNotifyingDidComplete(self)
    }
}

// MARK: - Settings UI (live connection status + last reading)

public final class CareSensAirSettingsViewController: UIViewController, CGMManagerOnboarding, CompletionNotifying {
    public weak var cgmManagerOnboardingDelegate: CGMManagerOnboardingDelegate?
    public weak var completionDelegate: CompletionDelegate?

    private let manager: CareSensAirCGMManager
    private let statusDot = UIView()
    private let statusValue = UILabel()
    private let glucoseValue = UILabel()

    private lazy var timeFormatter: DateFormatter = {
        let f = DateFormatter(); f.timeStyle = .short; f.dateStyle = .none; return f
    }()

    init(manager: CareSensAirCGMManager) {
        self.manager = manager
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    public override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemGroupedBackground
        title = "CareSens Air"

        let imageView = CareSensUI.sensorImageView(height: 120)

        let card = UIStackView(arrangedSubviews: [
            row("Status", valueLabel: statusValue, leadingDot: statusDot),
            separator(),
            row("Last reading", valueLabel: glucoseValue),
            separator(),
            staticRow("Serial", manager.serial),
            separator(),
            staticRow("PIN", manager.pin),
        ])
        card.axis = .vertical
        card.spacing = 0
        card.backgroundColor = .secondarySystemGroupedBackground
        card.layer.cornerRadius = 12
        card.isLayoutMarginsRelativeArrangement = true
        card.layoutMargins = UIEdgeInsets(top: 2, left: 16, bottom: 2, right: 16)

        let deleteButton = UIButton(type: .system)
        deleteButton.setTitle("Delete CGM", for: .normal)
        deleteButton.setTitleColor(.systemRed, for: .normal)
        deleteButton.titleLabel?.font = .preferredFont(forTextStyle: .body)
        deleteButton.addTarget(self, action: #selector(deleteManager), for: .touchUpInside)

        // Trio hosts this VC in a sheet with no navigation bar, so Done is an
        // in-content control.
        let doneButton = UIButton(type: .system)
        doneButton.setTitle("Done", for: .normal)
        doneButton.titleLabel?.font = .preferredFont(forTextStyle: .headline)
        doneButton.setTitleColor(.white, for: .normal)
        doneButton.backgroundColor = .systemBlue
        doneButton.layer.cornerRadius = 12
        doneButton.heightAnchor.constraint(equalToConstant: 52).isActive = true
        doneButton.addTarget(self, action: #selector(done), for: .touchUpInside)

        let stack = UIStackView(arrangedSubviews: [imageView, card, doneButton, deleteButton])
        stack.axis = .vertical
        stack.spacing = 20
        stack.setCustomSpacing(28, after: card)
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 24),
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
        ])
    }

    public override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        manager.statusDidChange = { [weak self] in self?.refresh() }
        refresh()
    }

    public override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        manager.statusDidChange = nil
    }

    private func refresh() {
        statusValue.text = manager.connectionStatusText
        statusDot.backgroundColor = manager.isConnected ? .systemGreen : .systemGray3
        if let g = manager.latestGlucose, let at = manager.latestGlucoseAt {
            glucoseValue.text = "\(g) mg/dL · \(timeFormatter.string(from: at))"
        } else {
            glucoseValue.text = "—"
        }
    }

    // MARK: Row builders

    private func row(_ title: String, valueLabel: UILabel, leadingDot: UIView? = nil) -> UIView {
        let titleLabel = UILabel()
        titleLabel.text = title
        titleLabel.font = .preferredFont(forTextStyle: .body)
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.setContentHuggingPriority(.required, for: .horizontal)
        titleLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        valueLabel.font = .preferredFont(forTextStyle: .body)
        valueLabel.adjustsFontForContentSizeCategory = true
        valueLabel.textColor = .secondaryLabel
        valueLabel.textAlignment = .right
        valueLabel.numberOfLines = 0

        let h = UIStackView()
        h.axis = .horizontal
        h.spacing = 8
        h.alignment = .center
        if let dot = leadingDot {
            dot.layer.cornerRadius = 5
            dot.backgroundColor = .systemGray3
            dot.translatesAutoresizingMaskIntoConstraints = false
            dot.widthAnchor.constraint(equalToConstant: 10).isActive = true
            dot.heightAnchor.constraint(equalToConstant: 10).isActive = true
            h.addArrangedSubview(dot)
        }
        h.addArrangedSubview(titleLabel)
        h.addArrangedSubview(valueLabel)
        h.isLayoutMarginsRelativeArrangement = true
        h.layoutMargins = UIEdgeInsets(top: 13, left: 0, bottom: 13, right: 0)
        return h
    }

    private func staticRow(_ title: String, _ value: String) -> UIView {
        let l = UILabel()
        l.text = value
        return row(title, valueLabel: l)
    }

    private func separator() -> UIView {
        let v = UIView()
        v.backgroundColor = .separator
        v.heightAnchor.constraint(equalToConstant: 0.5).isActive = true
        return v
    }

    // MARK: Actions

    @objc private func deleteManager() {
        let alert = UIAlertController(title: "Delete CareSens Air?",
                                      message: "Trio will stop receiving glucose from this sensor.",
                                      preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Delete CGM", style: .destructive) { [weak self] _ in
            guard let self = self else { return }
            self.manager.requestDeletion()
            self.complete()
        })
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        present(alert, animated: true)
    }

    @objc private func done() {
        complete()
    }

    /// Trio closes the hosting sheet when the completion delegate fires.
    private func complete() {
        completionDelegate?.completionNotifyingDidComplete(self)
    }
}
