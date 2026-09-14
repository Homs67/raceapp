//
//  CameraWidget.swift
//  raceApp
//
//  Live dual-camera preview in a large cell; tap toggles capture. The one
//  widget that reads the app model directly — preview layers are not
//  snapshot data — and only ever one per dashboard.
//

import SwiftUI

struct CameraWidget: View {
    let context: WidgetContext
    @Environment(AppModel.self) private var model
    @State private var frontIsPrimary = false

    var body: some View {
        Group {
            if !context.isEditing, model.camera.isCapturing, let rear = model.camera.rearPreviewLayer {
                DualCameraPreviewView(rearLayer: rear, frontLayer: model.camera.frontPreviewLayer,
                                      landscape: context.isLandscape, frontIsPrimary: $frontIsPrimary)
                    .onChange(of: model.camera.usesMultiCam) { _, multi in if !multi { frontIsPrimary = false } }
                    .onChange(of: model.camera.isCapturing) { _, on in if !on { frontIsPrimary = false } }
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    Spacer(minLength: 0)
                    Image(systemName: "camera.fill")
                        .font(.system(size: 34, weight: .medium))
                        .foregroundStyle(Color.mutedWeak)
                    WidgetCaption(text: model.camera.uiStatus == .unavailable
                                  ? "camera unavailable"
                                  : (context.live.isRecording ? "tap to turn on" : "records with the session"))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .contentShape(Rectangle())
        .onTapGesture {
            guard !context.isEditing else { return }
            model.toggleSessionCamera()
        }
        .accessibilityLabel("Camera preview")
    }
}
