//
//  BeatPageTextView.swift
//  BeatPagination2
//
//  Created by Lauri-Matti Parppei on 8.8.2025.
//

import UXKit
#if os(macOS)
import AppKit
#endif

// MARK: - Custom text view for rendered pages.

/// This is by all means a simple NS/UITextView, but on macOS it handles clicks to custom hyperlinks and esc presses. On iOS, we need to draw the view differently based on the drawing target to avoid rasterization.
@objc open class BeatPageTextView:UXTextView {
	weak var previewController:BeatPreviewManager?
    
#if os(macOS)
	/// The user clicked on a link, which direct to `Line` objects
	override public func clicked(onLink link: Any, at charIndex: Int) {
		// Viral: videos and websites open in the browser
		if let url = link as? URL {
			NSWorkspace.shared.open(url)
			return
		}
		guard
			let line = link as? Line,
			let previewController = self.previewController
		else { return }
		
		previewController.closeAndJumpToRange(line.textRange())
	}
	
	/// Videos and websites are pictures in the text: clicking one opens its address
	override public func mouseDown(with event: NSEvent) {
		if let lm = layoutManager, let tc = textContainer, let storage = textStorage {
			var point = convert(event.locationInWindow, from: nil)
			point.x -= textContainerOrigin.x
			point.y -= textContainerOrigin.y
			var fraction: CGFloat = 0
			let glyph = lm.glyphIndex(for: point, in: tc, fractionOfDistanceThroughGlyph: &fraction)
			if glyph < lm.numberOfGlyphs {
				let rect = lm.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: tc)
				let index = lm.characterIndexForGlyph(at: glyph)
				if rect.contains(point), index < storage.length,
				   storage.attribute(.attachment, at: index, effectiveRange: nil) != nil,
				   let url = storage.attribute(.link, at: index, effectiveRange: nil) as? URL {
					NSWorkspace.shared.open(url)
					return
				}
			}
		}
		super.mouseDown(with: event)
	}
	
	override public func cancelOperation(_ sender: Any?) {
		superview?.cancelOperation(sender)
	}
#else
    open override func draw(_ layer: CALayer, in ctx: CGContext) {
        let isPDF = !UIGraphicsGetPDFContextBounds().isEmpty

        if !self.layer.shouldRasterize && isPDF {
            self.draw(self.bounds)
        } else {
            super.draw(layer, in: ctx)
        }
    }
#endif
}
