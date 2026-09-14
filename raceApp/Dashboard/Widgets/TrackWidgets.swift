//
//  TrackWidgets.swift
//  raceApp
//
//  Altitude and heading.
//

import SwiftUI

struct AltitudeWidget: View {
    let context: WidgetContext

    var body: some View {
        HStack(alignment: .lastTextBaseline, spacing: 8) {
            WidgetSecondaryValue(text: context.live.altitude.map {
                String(Int(context.units.shortDistance(fromMeters: $0).rounded())) } ?? "—")
            WidgetCaption(text: context.units.shortDistanceUnit)
        }
    }
}

struct HeadingWidget: View {
    let context: WidgetContext

    private static let points = ["N", "NE", "E", "SE", "S", "SW", "W", "NW"]

    var body: some View {
        let h = context.live.heading
        HStack(alignment: .lastTextBaseline, spacing: 8) {
            WidgetSecondaryValue(text: h.map { String(Int($0.rounded())) + "°" } ?? "—")
            if let h {
                WidgetCaption(text: Self.points[Int(((h + 22.5).truncatingRemainder(dividingBy: 360)) / 45)])
            }
        }
    }
}
