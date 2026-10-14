import AVFoundation
import SwiftUI
import UIKit

/// Live camera preview that fills the screen.
struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession
    var onTap: ((CGPoint) -> Void)?

    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
        var onTap: ((CGPoint) -> Void)?

        override func layoutSubviews() {
            super.layoutSubviews()
            if let c = previewLayer.connection, c.isVideoRotationAngleSupported(90) { c.videoRotationAngle = 90 }
        }

        @objc func tapped(_ g: UITapGestureRecognizer) {
            let p = g.location(in: self)
            onTap?(previewLayer.captureDevicePointConverted(fromLayerPoint: p))
        }
    }

    func makeUIView(context: Context) -> PreviewView {
        let v = PreviewView()
        v.backgroundColor = .black
        v.previewLayer.session = session
        v.previewLayer.videoGravity = .resizeAspectFill
        v.onTap = onTap
        v.addGestureRecognizer(UITapGestureRecognizer(target: v, action: #selector(PreviewView.tapped(_:))))
        return v
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {
        uiView.onTap = onTap
    }
}
