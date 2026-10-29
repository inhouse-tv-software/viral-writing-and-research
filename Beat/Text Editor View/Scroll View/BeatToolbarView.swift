//
//  BeatToolbarView.swift
//  Beat macOS
//
//  Created by Lauri-Matti Parppei on 18.8.2026.
//  Copyright © 2026 Lauri-Matti Parppei. All rights reserved.
//

import AppKit
import BeatThemes

class BeatToolbarView:NSView {
	
	var leftBackground = CALayer()
	var rightBackground = CALayer()
	
	@IBOutlet weak var excludedView:NSView?
	
	/// Viral: shows the Info popover with shortcuts and page width
	let infoButton = NSButton(frame: .zero)
	
	override func awakeFromNib() {
		super.awakeFromNib()
		
		self.layer?.addSublayer(leftBackground)
		self.layer?.addSublayer(rightBackground)
		
		setupInfoButton()
		ViralPageWidth.shared.installMenu()
	}
	
	func setupInfoButton() {
		// Copy the look of the existing buttons on the right
		let template = rightButtons.first
		infoButton.bezelStyle = template?.bezelStyle ?? .regularSquare
		infoButton.isBordered = template?.isBordered ?? false
		infoButton.title = ""
		infoButton.imagePosition = .imageOnly
		infoButton.imageScaling = template?.imageScaling ?? .scaleProportionallyDown
		infoButton.contentTintColor = template?.contentTintColor
		let pointSize = template?.image.map { max(11, $0.size.height * 0.8) } ?? 13
		if let image = NSImage(systemSymbolName: "info.circle", accessibilityDescription: "Info") {
			infoButton.image = image.withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: pointSize, weight: .regular)) ?? image
		}
		infoButton.toolTip = "Info and shortcuts"
		infoButton.target = self
		infoButton.action = #selector(showInfo(_:))
		addSubview(infoButton)
		placeInfoButton()
	}
	
	/// Buttons in the right-hand group, left to right
	var rightButtons: [NSButton] {
		return subviews.compactMap { $0 as? NSButton }
			.filter { $0 !== infoButton && $0 !== excludedView && $0.frame.minX > frame.width / 2 && !$0.isHidden && $0.frame.height > 10 && $0.frame.width > 10 }
			.sorted { $0.frame.minX < $1.frame.minX }
	}
	
	/// The Info button sits to the left of the other buttons on the right, with the same size and spacing.
	/// It resizes with the toolbar the same way they do.
	private func placeInfoButton() {
		let buttons = rightButtons
		guard let first = buttons.first else { return }
		let spacing = buttons.count > 1 ? max(2, buttons[1].frame.minX - first.frame.maxX) : 6
		infoButton.autoresizingMask = first.autoresizingMask
		let frame = first.frame.offsetBy(dx: -(first.frame.width + spacing), dy: 0)
		if infoButton.frame != frame { infoButton.frame = frame }
	}
	
	@objc func showInfo(_ sender: NSButton) {
		ViralInfoController.show(from: sender)
	}
		
	override func layout() {
		super.layout()
		
		placeInfoButton()
		updateBackgrounds()
	}
	
	func updateBackgrounds() {
		let padding = 5.0
		let yPadding = 3.0
		
		var leftWidth = 0.0
		var leftX = self.frame.size.width
		
		var rightX = self.frame.size.width
		var rightWidth = 0.0
		
		var height = 0.0
		var y = 0.0
		
		for view in self.subviews.filter({ type(of: $0) is NSButton.Type }) {
			if view == excludedView { continue }
			
			if view.frame.origin.x < self.frame.width / 2 {
				leftX = min(leftX, view.frame.origin.x)
				leftWidth = max(leftWidth, view.frame.maxX - leftX)
				
				y = max(y, view.frame.minY)
				height = max(height, view.frame.height)
			} else {
				rightX = min(rightX, view.frame.minX)
				rightWidth = max(rightWidth, view.frame.maxX)
			}
		}
		
		y = (self.frame.size.height - (height + yPadding * 2)) / 2
		height = height + yPadding * 2
	
		CATransaction.begin()
		CATransaction.setDisableActions(true)
		
		leftBackground.frame = CGRect(x: leftX - padding, y: y, width: leftWidth + padding * 2, height: height)
		rightBackground.frame = CGRect(x: rightX - padding, y: y, width: rightWidth - rightX + padding * 2, height: height)
		
		leftBackground.cornerRadius = 8
		rightBackground.cornerRadius = 8
		
		leftBackground.backgroundColor = ThemeManager.shared().marginColor.withAlphaComponent(0.5).cgColor
		rightBackground.backgroundColor = ThemeManager.shared().marginColor.withAlphaComponent(0.5).cgColor
		
		CATransaction.commit()
	}
}
