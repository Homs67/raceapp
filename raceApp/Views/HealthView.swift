//
//  HealthView.swift
//  raceApp
//
//  Live vehicle-health gauges (design screen 4): slow OBD channels + device
//  health, car identity header, read-only DTC badge. Updates whenever
//  connected — recording not required (R3.4).
//

import SwiftUI
import SessionKit
import ObdKit

struct HealthView: View {
    @Environment(AppModel.self) private var model
    @AppStorage("useMetricUnits") private var metric = false

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            let now = uptimeNow()
            let snapshot = model.bus.snapshot()
            let units = UnitsFormatter(metric: metric)

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    header
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible())], spacing: 8) {
                        ForEach(cards(snapshot: snapshot, now: now, units: units)) { card in
                            HealthCard(card: card)
                        }
                    }
                }
                .padding(22)
            }
            .background(Color.bgScreen)
        }
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Health")
                    .font(.system(size: 34, weight: .bold))
                    .foregroundStyle(Color.textPrimary)
                Text(carSubtitle)
                    .font(.system(size: 15))
                    .foregroundStyle(Color.muted)
            }
            Spacer()
            if let milOn = model.connection.milOn {
                let codes = model.connection.dtcCount ?? 0
                let flagged = milOn || codes > 0
                Text("MIL \(milOn ? "ON" : "OFF") · \(codes) CODE\(codes == 1 ? "" : "S")")
                    .font(.microLabel(9)).kerning(1)
                    .foregroundStyle(flagged ? Color.recordRed : Color.mutedStrong)
                    .padding(.horizontal, 8).padding(.vertical, 5)
                    .overlay(RoundedRectangle(cornerRadius: 6)
                        .stroke(flagged ? Color.recordRed.opacity(0.6) : Color.cardBorder, lineWidth: 1))
                    .padding(.top, 6)
            }
        }
    }

    private var carSubtitle: String {
        let car = model.connection.carInfo
        if let make = car?.make {
            let name = "\(make) \(car?.model ?? "")".trimmingCharacters(in: .whitespaces)
            if let vin = car?.vin { return "\(name) · \(vin)" }
            return name
        }
        return model.connection.carLinkUp ? "Connected" : model.connection.stateDescription
    }

    // MARK: - Cards

    private func cards(snapshot: [ChannelId: TelemetryReading], now: TimeInterval,
                       units: UnitsFormatter) -> [CardModel] {
        func card(_ label: String, _ channel: ChannelId, unit: String,
                  maxAge: TimeInterval = 15,
                  transform: (Double) -> Double = { $0 },
                  format: String = "%.0f",
                  color: (Double) -> Color = { _ in .textPrimary },
                  fraction: (Double) -> Double = { _ in 0 }) -> CardModel {
            let raw = snapshot.fresh(channel, now: now, maxAge: maxAge)
            let age = snapshot.age(channel, now: now)
            let staleNote: String? = {
                guard let age, age > 10, raw != nil else { return raw == nil && age != nil ? ">\(Int(maxAge))s stale" : nil }
                return "\(Int(age))s ago"
            }()
            return CardModel(
                id: channel.rawValue,
                label: label,
                value: raw.map { String(format: format, transform($0)) },
                unit: unit,
                age: staleNote,
                color: raw.map(color) ?? .mutedWeak,
                barFraction: raw.map(fraction) ?? 0
            )
        }

        return [
            card("COOLANT", .obd(.coolantTemp), unit: units.tempUnit,
                 transform: units.temp(fromC:),
                 color: { $0 < 75 ? .accentCyan : $0 <= 105 ? .okGreen : .recordRed },
                 fraction: { min(1, $0 / 130) }),
            card("OIL TEMP", .obd(.oilTemp), unit: units.tempUnit,
                 transform: units.temp(fromC:),
                 color: { $0 <= 120 ? .okGreen : .recordRed },
                 fraction: { min(1, $0 / 150) }),
            card("INTAKE AIR", .obd(.intakeAirTemp), unit: units.tempUnit,
                 transform: units.temp(fromC:), fraction: { min(1, $0 / 80) }),
            card("AMBIENT", .obd(.ambientTemp), unit: units.tempUnit,
                 transform: units.temp(fromC:), fraction: { min(1, $0 / 50) }),
            card("FUEL LEVEL", .obd(.fuelLevel), unit: "%",
                 color: { $0 < 20 ? .warnAmber : .textPrimary },
                 fraction: { $0 / 100 }),
            card("BATTERY", .obd(.controlModuleVoltage), unit: "V", format: "%.1f",
                 color: { $0 < 12.5 ? .warnAmber : .okGreen },
                 fraction: { min(1, $0 / 16) }),
            card("ENGINE LOAD", .obd(.engineLoad), unit: "%", maxAge: 5,
                 fraction: { $0 / 100 }),
            card("BARO", .obd(.barometricPressure), unit: metric ? "hPa" : "inHg",
                 transform: { metric ? $0 * 10 : $0 * 0.2953 },
                 format: metric ? "%.0f" : "%.2f"),
            card("TIMING ADV", .obd(.timingAdvance), unit: "°BTDC", format: "%.1f"),
            card("REL. ELEVATION", .baroRelativeAltitude,
                 unit: units.shortDistanceUnit, maxAge: 30,
                 transform: units.shortDistance(fromMeters:),
                 color: { _ in .accentCyan }),
            card("PHONE BATTERY", .deviceBattery, unit: "%", maxAge: 30,
                 transform: { $0 * 100 },
                 color: { $0 < 0.2 ? .warnAmber : .textPrimary },
                 fraction: { $0 }),
            thermalCard(snapshot: snapshot, now: now),
        ]
    }

    private func thermalCard(snapshot: [ChannelId: TelemetryReading], now: TimeInterval) -> CardModel {
        let raw = snapshot.fresh(.deviceThermalState, now: now, maxAge: 30)
        let labels = ["NOMINAL", "FAIR", "SERIOUS", "CRITICAL"]
        let colors: [Color] = [.okGreen, .textPrimary, .warnAmber, .recordRed]
        let index = raw.map { min(3, max(0, Int($0))) }
        return CardModel(
            id: "device.thermal",
            label: "THERMAL",
            value: index.map { labels[$0] },
            unit: "",
            age: nil,
            color: index.map { colors[$0] } ?? .mutedWeak,
            barFraction: index.map { Double($0 + 1) / 4 } ?? 0
        )
    }
}

private struct CardModel: Identifiable {
    let id: String
    let label: String
    let value: String?
    let unit: String
    let age: String?
    let color: Color
    let barFraction: Double
}

private struct HealthCard: View {
    let card: CardModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(card.label)
                    .font(.microLabel(9)).kerning(1.2)
                    .foregroundStyle(Color.muted)
                Spacer()
                if let age = card.age {
                    Text(age)
                        .font(.system(size: 9))
                        .foregroundStyle(Color.warnAmber)
                }
            }
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(card.value ?? "—")
                    .font(.numeral(25, weight: .medium))
                    .foregroundStyle(card.value == nil ? Color.mutedWeak : card.color)
                if card.value != nil, !card.unit.isEmpty {
                    Text(card.unit)
                        .font(.system(size: 11))
                        .foregroundStyle(Color.muted)
                }
            }
            RoundedRectangle(cornerRadius: 1.5)
                .fill(card.value == nil ? Color.cardBorder : card.color.opacity(0.8))
                .frame(height: 3)
                .frame(maxWidth: .infinity, alignment: .leading)
                .mask(alignment: .leading) {
                    GeometryReader { geo in
                        Rectangle().frame(width: max(3, geo.size.width * card.barFraction))
                    }
                }
                .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 1.5))
        }
        .padding(EdgeInsets(top: 11, leading: 13, bottom: 11, trailing: 13))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.cardGray, in: RoundedRectangle(cornerRadius: 16))
    }
}
