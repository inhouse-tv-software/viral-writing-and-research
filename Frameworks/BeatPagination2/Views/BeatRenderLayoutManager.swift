//
//  BeatRenderLayoutManager.swift
//  BeatPagination2
//
//  Created by Lauri-Matti Parppei on 8.8.2025.
//

import UXKit

// MARK: - Custom layout manager for text views in rendered page view

public class BeatRenderLayoutManager:NSLayoutManager, NSLayoutManagerDelegate {
	weak var pageView:BeatPaginationPageView?
    
    public override init() {
        super.init()
        self.delegate = self
    }
    
    public required init?(coder: NSCoder) {
        super.init(coder: coder)
    }
    
	override public func drawGlyphs(forGlyphRange glyphsToShow: NSRange, at origin: CGPoint) {
		super.drawGlyphs(forGlyphRange: glyphsToShow, at: origin)
		
		let container = self.textContainers.first!
        let revisions = pageView?.settings.revisions as? IndexSet ?? []
        let charRange = self.characterRange(forGlyphRange: glyphsToShow, actualGlyphRange: nil)
        
		if ((pageView?.isTitlePage ?? false)) {
			return
		}
		
        #if os(macOS)
		NSGraphicsContext.saveGraphicsState()
        #endif
                        
		self.enumerateLineFragments(forGlyphRange: glyphsToShow) { rect, usedRect, textContainer, originalRange, stop in
			let markerRect = CGRectMake(container.size.width - 10 - (self.pageView?.pageStyle.marginRight ?? 0.0), usedRect.origin.y - 3.0, 15, usedRect.size.height)
			
			var highestRevision = -1
			var range = originalRange
            
			// This is a fix for some specific languages. Sometimes you might have more characters in range than what are stored in text storage.
			if (NSMaxRange(range) > self.textStorage!.string.count) {
				let len = max(self.textStorage!.string.count - NSMaxRange(range), 0)
				range = NSMakeRange(range.location, len)
				
				if (range.length == 0) {
					return
				}
			}
            
            // In rendered text, the revision attribute is a A NUMBER VALUE
			self.textStorage?.enumerateAttribute(NSAttributedString.Key(BeatRevisions.attributeKey()), in: range) { obj, attrRange, stop in
                guard obj != nil, let revisionValue = obj as? NSNumber else { return }
                
                let level = revisionValue.intValue

				// If the revision is not included in settings, just skip it.
                if !revisions.contains(level) { return }
				                
                if highestRevision < level {
					highestRevision = level
				}
			}
            
			if highestRevision == -1 { return }
			
            let generation = BeatRevisions.revisionGenerations()[highestRevision]
            
            let marker:NSString = generation.marker as NSString
            let font = BeatFontManager.shared.defaultFonts.regular
			marker.draw(at: markerRect.origin, withAttributes: [
				NSAttributedString.Key.font: font,
				NSAttributedString.Key.foregroundColor: UXColor.black
			])
		}
        
        if let settings = pageView?.settings, settings.printDialogueNumbers {
            drawDialogueNumbers(characterRange: charRange)
        }
        		
        #if os(macOS)
		NSGraphicsContext.restoreGraphicsState()
        #endif
	}
	
    private func drawDialogueNumbers(characterRange:NSRange) {
        guard let container = self.textContainers.first, let pageStyle = pageView?.pageStyle else { return }
        
        self.textStorage?.enumerateAttribute(NSAttributedString.Key("DialogueNumber"), in: characterRange) { obj, attrRange, stop in
            guard let val = obj as? NSNumber else { return }
            
            let glyphRange = self.glyphRange(forCharacterRange: attrRange, actualCharacterRange: nil)
            let usedRect = self.boundingRect(forGlyphRange: glyphRange, in: self.textContainers.first!)
            
            let num = String(val.intValue)
            let font = BeatFontManager.shared.defaultFonts.regular
            
            var numRect = CGRectMake(0, usedRect.origin.y, 50, usedRect.size.height)
            if let textStorage, let val = textStorage.attribute(NSAttributedString.Key("LineType"), at: attrRange.location, effectiveRange: nil) as? UInt, let lineType = LineType(rawValue: val) {
                if lineType == .dualDialogue {
                    numRect.origin.x = container.size.width - 30 - pageStyle.marginRight
                }
            }
            
            num.draw(at: numRect.origin, withAttributes: [
                NSAttributedString.Key.font: font,
                NSAttributedString.Key.foregroundColor: UXColor.black
            ])
        }
    }
    
	override public func drawBackground(forGlyphRange glyphsToShow: NSRange, at origin: CGPoint) {
		super.drawBackground(forGlyphRange: glyphsToShow, at: origin)
        drawHighlight(forGlyphRange: glyphsToShow)
        drawTables(forGlyphRange: glyphsToShow, origin: origin)
	}
    
    // MARK: - Tables
    
    /// Draws grid lines for table rows (marked with `BeatTableRow` attribute by the renderer)
    func drawTables(forGlyphRange glyphRange: NSRange, origin: CGPoint) {
        guard let textStorage, let container = self.textContainers.first else { return }
        
        let key = NSAttributedString.Key("BeatTableRow")
        let range = self.characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil)
        
        textStorage.enumerateAttribute(key, in: range) { value, rowRange, stop in
            guard let info = value as? [String: Any],
                  let pipes = info["pipes"] as? [NSNumber],
                  rowRange.length > 0
            else { return }
            
            // Separator rows are not drawn
            if (info["separator"] as? Bool) ?? false { return }
            
            // Check neighboring rows. Index - 1 is the line break of the previous row.
            var firstRow = true
            if rowRange.location >= 2, textStorage.attribute(key, at: rowRange.location - 2, effectiveRange: nil) != nil {
                firstRow = false
            }
            
            var headerRow = false
            let nextIndex = NSMaxRange(rowRange) + 1
            if firstRow, nextIndex < textStorage.length,
               let next = textStorage.attribute(key, at: nextIndex, effectiveRange: nil) as? [String: Any],
               (next["separator"] as? Bool) ?? false {
                headerRow = true
            }
            
            var xs: [CGFloat] = []
            for p in pipes {
                let charIndex = rowRange.location + p.intValue
                guard charIndex < textStorage.length else { continue }
                let glyphIndex = self.glyphIndexForCharacter(at: charIndex)
                let r = self.boundingRect(forGlyphRange: NSMakeRange(glyphIndex, 1), in: container)
                xs.append(origin.x + r.midX)
            }
            
            guard xs.count >= 2, let left = xs.first, let right = xs.last else { return }
            
            let firstGlyph = self.glyphIndexForCharacter(at: rowRange.location)
            let lastGlyph = self.glyphIndexForCharacter(at: NSMaxRange(rowRange) - 1)
            let topRect = self.lineFragmentUsedRect(forGlyphAt: firstGlyph, effectiveRange: nil)
            let bottomRect = self.lineFragmentUsedRect(forGlyphAt: lastGlyph, effectiveRange: nil)
            
            let top = origin.y + topRect.origin.y
            let bottom = origin.y + bottomRect.maxY
            let height = bottom - top
            
            if headerRow {
                UXColor(white: 0.92, alpha: 1.0).setFill()
                self.fillTableRect(CGRect(x: left, y: top, width: right - left, height: height))
            }
            
            UXColor(white: 0.45, alpha: 1.0).setFill()
            
            for x in xs {
                self.fillTableRect(CGRect(x: x - 0.25, y: top, width: 0.5, height: height))
            }
            
            if firstRow {
                self.fillTableRect(CGRect(x: left - 0.25, y: top, width: right - left + 0.5, height: 0.5))
            }
            self.fillTableRect(CGRect(x: left - 0.25, y: bottom - 0.5, width: right - left + 0.5, height: 0.5))
        }
    }
    
    private func fillTableRect(_ rect: CGRect) {
        #if os(iOS)
        UIRectFill(rect)
        #else
        rect.fill()
        #endif
    }
    
    /// Draws background highlights (for `Highlight` attribute) for given glyph range. Called in `drawBackground`.
    func drawHighlight(forGlyphRange glyphRange:NSRange) {
        let range = self.characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil)
        
        self.textStorage?.enumerateAttribute(NSAttributedString.Key("Highlight"), in: range) { val, highlightRange, stop in
            guard val != nil else { return }
            
            let gr = self.glyphRange(forCharacterRange: highlightRange, actualCharacterRange: nil)
            let rects = self.rectsForGlyphRange(gr)
            
            let c = UXColor.yellow.withAlphaComponent(0.9)
            c.setFill()
            
            for rectValue in rects {
                #if os(iOS)
                    let rect = rectValue.cgRectValue
                    UIRectFill(rect)
                #else
                    let rect = rectValue.rectValue
                    rect.fill()
                #endif
            }
        }
    }
    
    @objc func lineFragmentRanges() -> [NSRange] {
        guard let textStorage else { return [] }
        
        var ranges:[NSRange] = []
        
        let glyphRange = self.glyphRange(forCharacterRange: NSMakeRange(0, textStorage.length), actualCharacterRange: nil)
        enumerateLineFragments(forGlyphRange: glyphRange) { rect, bounds, container, range, stop in
            let charRange = self.characterRange(forGlyphRange: range, actualGlyphRange: nil)
            if charRange.length > 0 {
                ranges.append(charRange)
            }
        }
        
        return ranges
    }
    
    @objc func stringInRange(_ range:NSRange) -> String? {
        guard let textStorage, NSMaxRange(range) <= textStorage.length else { return nil }
        
        return textStorage.string.substring(range: range)
    }
    
    func representedLineUUIDs(inRange:NSRange) -> [NSRange:String?] {
        guard let textStorage else { return [:] }
        
        var uuids:[NSRange:String] = [:]
        //let ranges: [NSRange] = self.lineFragmentRanges()
        
        textStorage.enumerateAttribute(NSAttributedString.Key(BeatRepresentedLineKey), in: textStorage.range) { value, range, stop in
            if let line = value as? Line {
                uuids[range] = line.uuidString()
            }
        }
        
        return uuids
    }
    
    
    /// This is a delegate trick to hold some Japanese and Chinese fonts constrained to the actual size that was paginated. For some reason, internal pagination code handles the Japanese sizing just well, but once it is rendered out, the slightly higher fonts start to drift. We'll forcibly set the line fragment rect when that happens.
    public func layoutManager(
        _ layoutManager: NSLayoutManager,
        shouldSetLineFragmentRect lineFragmentRect: UnsafeMutablePointer<CGRect>,
        lineFragmentUsedRect: UnsafeMutablePointer<CGRect>,
        baselineOffset: UnsafeMutablePointer<CGFloat>,
        in textContainer: NSTextContainer,
        forGlyphRange glyphRange: NSRange
    ) -> Bool {
        let chrRange = self.characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil)
        
        guard let textStorage,
              let paragraphStyle = textStorage.attribute(.paragraphStyle, at: chrRange.location, effectiveRange: nil) as? NSParagraphStyle
        else { return false }
        
        let allowedHeight = paragraphStyle.maximumLineHeight + paragraphStyle.paragraphSpacingBefore + paragraphStyle.paragraphSpacing
        let proposedHeight = lineFragmentRect.pointee.height
        
        // If the proposed height is higher than what we are expecting from styles, let's not allow that. Baseline stays the same.
        if proposedHeight > allowedHeight {
            lineFragmentRect.pointee = CGRectMake(lineFragmentRect.pointee.origin.x, lineFragmentRect.pointee.origin.y, lineFragmentRect.pointee.width, allowedHeight)
            return true
        } else {
            return false
        }
    }
}
