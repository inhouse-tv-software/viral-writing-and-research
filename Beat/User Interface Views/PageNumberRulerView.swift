//
//  PageNumberRulerView.swift
//  Beat macOS
//
//  Created by Lauri-Matti Parppei on 15.1.2026.
//  Copyright © 2026 Lauri-Matti Parppei. All rights reserved.
//

import BeatCore

class PageNumberRulerView: NSRulerView, BeatSceneOutlineView {
		
	var font: NSFont! {
		didSet {
			self.needsDisplay = true
		}
	}
	
	weak var delegate:BeatEditorDelegate?
	
	init(outlineView: BeatOutlineView, delegate: BeatEditorDelegate) {
		super.init(scrollView: outlineView.enclosingScrollView!, orientation: NSRulerView.Orientation.verticalRuler)
		
		self.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
		
		self.delegate = delegate
		self.clientView = outlineView
		
		self.ruleThickness = 40
		self.layer?.backgroundColor = NSColor.clear.cgColor
		self.wantsLayer = true
	}
	
	required init(coder: NSCoder) {
		fatalError("init(coder:) has not been implemented")
	}
	
	
	override func drawHashMarksAndLabels(in rect: NSRect) {
		guard let delegate,
			  let outlineView = self.clientView as? BeatOutlineView,
			  let pagination = delegate.pagination().finishedPagination else { return }
		
		let attributes: [NSAttributedString.Key: Any] = [
			.font: self.font!,
			.foregroundColor: NSColor.gray
		]
		
		let drawPageNumber = { (pgNumber: String, y: CGFloat, height: CGFloat) -> Void in
			let attrStr = NSAttributedString(string: pgNumber, attributes: attributes)
			let x = 35 - attrStr.size().width
			
			// Draw background
			let bgRect = CGRect(x: 0, y: y, width: self.frame.width, height: height)
			ThemeManager.shared().outlineBackground.setFill()
			bgRect.fill()
			
			// Draw separator line
			let separator = CGRect(x: 0, y: y, width: self.frame.width, height: 1)
			NSColor.gray.withAlphaComponent(0.5).setFill()
			separator.fill()
			
			// Draw page number
			attrStr.draw(at: CGPoint(x: x, y: y + 2))
		}
		
		var previousPageNumber = 0
		
		delegate.parser.scenes().forEach { scene in
			let row = outlineView.row(forItem: scene)
			guard row >= 0 else { return } // Skip if item not found
			
			let rowRect = outlineView.rect(ofRow: row)
			
			// Convert the row's Y position directly to ruler coordinates
			let yInRuler = outlineView.convert(CGPoint(x: 0, y: rowRect.minY), to: self).y
			
			// Only draw if within the visible rect
			guard rect.contains(CGPoint(x: 0, y: yInRuler)) ||
				  (yInRuler >= rect.minY - 20 && yInRuler <= rect.maxY + 20) else { return }
			
			let pageNumber = pagination.pageNumber(for: scene)
			if pageNumber > previousPageNumber {
				previousPageNumber = pageNumber
				drawPageNumber("\(pageNumber)", yInRuler, rect.size.height)
			}
		}
	}
	
	public func didMove(toSceneIndex index: Int) {
		//
	}
	
	public func reloadInBackground() {
		self.needsDisplay = true
	}
	
	public func reload() {
		self.needsDisplay = true
	}
	
	public func visible() -> Bool {
		return self.enclosingScrollView?.hasVerticalScroller ?? false
	}
	
	@IBAction func togglePageNumbers(_ sender:Any?) {
		self.enclosingScrollView?.hasVerticalRuler.toggle()
	}
	
	func reload(with changes: OutlineChanges!) {
		self.needsDisplay = true
	}

}

var LineNumberViewAssocObjKey: UInt8 = 0

@objc extension BeatOutlineView {
	
	var pageNumberView:PageNumberRulerView {
		get {
			return objc_getAssociatedObject(self, &LineNumberViewAssocObjKey) as! PageNumberRulerView
		}
		set {
			objc_setAssociatedObject(self, &LineNumberViewAssocObjKey, newValue, objc_AssociationPolicy.OBJC_ASSOCIATION_RETAIN_NONATOMIC)
		}
	}
	
	@objc func setupPageNumberView() {
		if let scrollView = enclosingScrollView {
			pageNumberView = PageNumberRulerView(outlineView: self, delegate: self.editorDelegate)
			
			scrollView.verticalRulerView = pageNumberView
			scrollView.hasVerticalRuler = true
			scrollView.rulersVisible = true
		}
		
		postsFrameChangedNotifications = true
		NotificationCenter.default.addObserver(self, selector: #selector(lnv_textDidChange), name: NSText.didChangeNotification, object: self)
	}
	
	@objc func lnv_framDidChange(notification: NSNotification) {
		pageNumberView.needsDisplay = true
	}
	
	@objc func lnv_textDidChange(notification: NSNotification) {
		
		pageNumberView.needsDisplay = true
	}
	
}
