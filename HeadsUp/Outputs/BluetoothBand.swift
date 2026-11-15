import CoreBluetooth
import Foundation

/// The real wristband over Bluetooth Low Energy (Core Bluetooth).
///
/// Connection, step by step:
///  1. Wait for the phone's Bluetooth to be on (and allowed).
///  2. Scan for a device advertising the band's service.
///  3. Connect to it (and keep a reference, or iOS drops the connection).
///  4. Find the service's command characteristic.
///  5. Write motor commands to it, without waiting for a reply.
/// If the band drops out, go back to step 2. The firmware advertises again by itself.
///
/// `write` takes the same level packet as the simulated band, `[first motor, second motor]`
/// (each 0–3), and turns it into the firmware's one-command-per-motor format.
final class BluetoothBand: NSObject, BandTransport, @unchecked Sendable {
  enum State: Equatable, Sendable {
    case unavailable  // this device has no Bluetooth LE (the simulator)
    case bluetoothOff
    case notAllowed
    case searching
    case connecting
    case connected

    var text: String {
      switch self {
      case .unavailable: return "Band: Bluetooth not available on this device"
      case .bluetoothOff: return "Band: Bluetooth is off"
      case .notAllowed: return "Band: Bluetooth permission needed"
      case .searching: return "Band: searching"
      case .connecting: return "Band: connecting"
      case .connected: return "Band: connected"
      }
    }
  }

  /// Called on a background queue whenever the connection state changes.
  var onState: (@Sendable (State) -> Void)?

  private let queue = DispatchQueue(label: "headsup.band.bluetooth", qos: .userInitiated)
  private let service = CBUUID(string: BandConstants.serviceUUID)
  private let characteristicID = CBUUID(string: BandConstants.commandCharacteristicUUID)
  // Everything below is touched only on `queue`.
  private var central: CBCentralManager?
  private var peripheral: CBPeripheral?
  private var characteristic: CBCharacteristic?
  private var state = State.searching

  /// Starts Bluetooth. iOS asks for permission the first time.
  func start() {
    queue.async {
      guard self.central == nil else { return }
      self.central = CBCentralManager(delegate: self, queue: self.queue)
    }
  }

  func write(_ packet: [UInt8]) {
    queue.async {
      guard let peripheral = self.peripheral, let characteristic = self.characteristic else { return }
      for command in BandConstants.commands(forLevels: packet) {
        // No reply wanted: a lost command is replaced by the next heartbeat 200 ms later.
        peripheral.writeValue(Data(command), for: characteristic, type: .withoutResponse)
      }
    }
  }

  private func set(_ newState: State) {
    guard newState != state else { return }
    state = newState
    onState?(newState)
  }

  private func scan() {
    guard let central, central.state == .poweredOn else { return }
    peripheral = nil
    characteristic = nil
    set(.searching)
    central.scanForPeripherals(withServices: [service])
  }
}

extension BluetoothBand: CBCentralManagerDelegate {
  func centralManagerDidUpdateState(_ central: CBCentralManager) {
    switch central.state {
    case .poweredOn: scan()
    case .poweredOff: set(.bluetoothOff)
    case .unauthorized: set(.notAllowed)
    case .unsupported: set(.unavailable)
    default: break  // resetting / unknown: wait for the next update
    }
    if central.state != .poweredOn {
      peripheral = nil
      characteristic = nil
    }
  }

  func centralManager(
    _ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
    advertisementData: [String: Any], rssi RSSI: NSNumber
  ) {
    central.stopScan()
    self.peripheral = peripheral
    peripheral.delegate = self
    set(.connecting)
    central.connect(peripheral)
  }

  func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
    peripheral.discoverServices([service])
  }

  func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
    scan()
  }

  func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
    scan()
  }
}

extension BluetoothBand: CBPeripheralDelegate {
  func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
    guard let found = peripheral.services?.first(where: { $0.uuid == service }) else {
      central?.cancelPeripheralConnection(peripheral)
      return
    }
    peripheral.discoverCharacteristics([characteristicID], for: found)
  }

  func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
    guard let found = service.characteristics?.first(where: { $0.uuid == characteristicID }) else {
      central?.cancelPeripheralConnection(peripheral)
      return
    }
    characteristic = found
    set(.connected)
  }
}

/// Sends every packet to several transports (the real band and the on-screen one).
final class BandFanout: BandTransport, @unchecked Sendable {
  private let transports: [BandTransport]
  init(_ transports: [BandTransport]) { self.transports = transports }
  func write(_ packet: [UInt8]) { transports.forEach { $0.write(packet) } }
}
