//
//  BeatTextView+TabBehavior.swift
//  Beat macOS
//
//  Created by Lauri-Matti Parppei on 27.10.2025.
//  Copyright © 2025 Lauri-Matti Parppei. All rights reserved.
//

import Foundation
import AppKit
import UniformTypeIdentifiers
import WebKit
import BeatCore

public extension BeatTextView {
	@objc func handleTabPress() {
		guard let editorDelegate,
			  let currentLine = editorDelegate.currentLine
		else { return }
		
		if currentLine.isAnyCharacter(),
		   currentLine.string.count > 0 {
			if self.text.position(insideParentheticals: self.selectedRange.lowerBound) {
				editorDelegate.textActions.moveToNextDialogueLineOrAddNew()
			} else {
				editorDelegate.formattingActions.addOrEditCharacterExtension()
			}
		} else if currentLine.isAnyDialogue(),
				  currentLine.string.count == 0 {
			editorDelegate.textActions.add("()", at: UInt(currentLine.position))
			self.selectedRange = NSRange(location: currentLine.position + 1, length: 0)
		} else if currentLine.isAnyParenthetical(), currentLine.string == "()" {
			// We'll delete the empty parenthetical. Either the full range or just the text range.
			let nextLine = editorDelegate.parser.nextLine(currentLine)
			
			let range = nextLine != nil ? currentLine.textRange() : currentLine.range()
			editorDelegate.textActions.replace(range, with: "")
			
			// If there was a next line and it was empty, we'll add a new character cue
			if let nextLine, nextLine.type == .empty {
				self.forceCharacterInput()
			}
			
		} else {
			self.forceCharacterInput()
		}
	}
	
	@objc func forceCharacterInput() {
		guard let editorDelegate, editorDelegate.lineForNewCue == nil else { return }
		
		editorDelegate.formattingActions.addCue()
	}
}

// MARK: - Tables
/*
 
 Notion-style tables.
 
 In the document, tables are stored as Markdown pipe tables (so other apps can read them):
 
 | Item | Price | Notes          |
 |---|---|---|
 | Soya | 120 | Line one<br>Line two |
 
 In the editor the table text is hidden (see BeatLayoutManager) and a `BeatTableView` is placed
 on top of it. Each cell is a small text view. Editing a cell writes the Markdown back to the document,
 so undo, saving and printing work as usual.
 
 Keys inside a cell:
 - Shift+Return: new line inside the cell
 - Return: move to the cell below (adds a row at the bottom)
 - Tab / Shift+Tab: next / previous cell (Tab on the last cell adds a row)
 - Up / Down on the first / last line of a cell: move between rows, or out of the table
 - Esc: leave the table
 
 Type `/table` (or `/table 4x3`) and press Return to insert a table.
 
 */

fileprivate let BeatTableMenuItemTag = 947_100
fileprivate var BeatTableViewsKey: UInt8 = 0
fileprivate var BeatTableUpdateScheduledKey: UInt8 = 0
fileprivate var BeatTableWritingKey: UInt8 = 0
fileprivate var BeatTableObserversKey: UInt8 = 0
fileprivate var BeatTableHeightCacheKey: UInt8 = 0
fileprivate var BeatTablePendingFocusKey: UInt8 = 0
fileprivate var ViralBlockCacheKey: UInt8 = 0
fileprivate var ViralPlayerCheckKey: UInt8 = 0

/// Remembers where tables and images are, so the whole document is only scanned again after the text changed
/// (and not on every layout pass while scrolling).
fileprivate final class ViralBlockCache {
	var version = 0
	var tableKey = (version: -1, length: -1)
	var embedKey = (version: -1, length: -1)
	var tables: [Any] = []
	var embeds: [Any] = []
}

fileprivate enum BTMetrics {
	static let paddingX: CGFloat = 8
	static let paddingY: CGFloat = 5
	static let marginTop: CGFloat = 8
	/// Room for the "add row" button below the table
	static let marginBottom: CGFloat = 26
	static let addButtonSize: CGFloat = 18
	static let border: CGFloat = 1
}

// MARK: Table model

fileprivate struct BeatTableModel {
	var rows: [[String]]
	
	var columnCount: Int { return rows.first?.count ?? 1 }
	func emptyRow() -> [String] { return Array(repeating: "", count: columnCount) }
	
	static func isRow(_ s: String) -> Bool {
		// Only spaces, like the layout manager and the printed version
		let t = s.trimmingCharacters(in: CharacterSet(charactersIn: " "))
		return t.count >= 2 && t.hasPrefix("|") && t.hasSuffix("|")
	}
	
	static func isSeparator(_ s: String) -> Bool {
		guard isRow(s), s.contains("-") else { return false }
		return s.allSatisfy { $0 == "|" || $0 == "-" || $0 == ":" || $0 == " " }
	}
	
	static func cells(_ line: String) -> [String] {
		var t = line.trimmingCharacters(in: .whitespaces)
		if t.hasPrefix("|") { t.removeFirst() }
		if t.hasSuffix("|") && !t.hasSuffix("\\|") { t.removeLast() }
		
		var cells: [String] = []
		var current = ""
		var escaped = false
		for ch in t {
			if escaped {
				if ch != "|" && ch != "-" && ch != "\\" { current.append("\\") }
				current.append(ch)
				escaped = false
			} else if ch == "\\" {
				escaped = true
			} else if ch == "|" {
				cells.append(current)
				current = ""
			} else {
				current.append(ch)
			}
		}
		if escaped { current.append("\\") }
		cells.append(current)
		
		return cells.map { cell in
			var c = cell.trimmingCharacters(in: .whitespaces)
			for br in ["<br/>", "<br />", "<BR/>", "<BR />", "<br>", "<BR>"] {
				c = c.replacingOccurrences(of: br, with: "\n")
			}
			return c
		}
	}
	
	static func parse(_ lines: [String]) -> BeatTableModel {
		var rows = lines.filter { !isSeparator($0) }.map { cells($0) }
		if rows.isEmpty { rows = [[""]] }
		let cols = max(rows.map { $0.count }.max() ?? 1, 1)
		rows = rows.map { $0 + Array(repeating: "", count: cols - $0.count) }
		return BeatTableModel(rows: rows)
	}
	
	static func escape(_ cell: String) -> String {
		var c = cell.replacingOccurrences(of: "\\", with: "\\\\")
		c = c.replacingOccurrences(of: "|", with: "\\|")
		c = c.replacingOccurrences(of: "\r", with: "")
		c = c.replacingOccurrences(of: "\u{2028}", with: "\n")
		c = c.replacingOccurrences(of: "\n", with: "<br>")
		return c
	}
	
	func serialize() -> String {
		var lines: [String] = []
		for (i, row) in rows.enumerated() {
			var cells = row.map { BeatTableModel.escape($0) }
			// A row of dashes would look like a header separator, so escape the first dash
			let line = "| " + cells.joined(separator: " | ") + " |"
			if BeatTableModel.isSeparator(line), let first = cells.firstIndex(where: { $0.contains("-") }) {
				cells[first] = cells[first].replacingOccurrences(of: "-", with: "\\-", options: [], range: cells[first].range(of: "-"))
			}
			lines.append("| " + cells.joined(separator: " | ") + " |")
			if i == 0 {
				lines.append("|" + Array(repeating: "---", count: columnCount).joined(separator: "|") + "|")
			}
		}
		return lines.joined(separator: "\n")
	}
}

// MARK: Measuring

fileprivate final class BTMeasurer {
	static let shared = BTMeasurer()
	let storage = NSTextStorage()
	let layoutManager = NSLayoutManager()
	let container = NSTextContainer(size: NSSize(width: 100, height: CGFloat.greatestFiniteMagnitude))
	
	init() {
		container.lineFragmentPadding = 0
		layoutManager.addTextContainer(container)
		storage.addLayoutManager(layoutManager)
	}
	
	func height(_ text: String, width: CGFloat, font: NSFont) -> CGFloat {
		var string = text.isEmpty ? " " : text
		if string.hasSuffix("\n") { string += " " }
		storage.setAttributedString(NSAttributedString(string: string, attributes: [.font: font]))
		container.size = NSSize(width: max(width, 10), height: CGFloat.greatestFiniteMagnitude)
		layoutManager.ensureLayout(for: container)
		return ceil(layoutManager.usedRect(for: container).height)
	}
}

fileprivate func btColumnWidth(_ tableWidth: CGFloat, columns: Int) -> CGFloat {
	let n = CGFloat(max(columns, 1))
	return floor((tableWidth - BTMetrics.border * (n + 1)) / n)
}

fileprivate func btRowHeights(_ model: BeatTableModel, tableWidth: CGFloat, font: NSFont) -> [CGFloat] {
	let colWidth = btColumnWidth(tableWidth, columns: model.columnCount)
	let textWidth = colWidth - BTMetrics.paddingX * 2
	return model.rows.map { row in
		let h = row.map { BTMeasurer.shared.height($0, width: textWidth, font: font) }.max() ?? 0
		return h + BTMetrics.paddingY * 2
	}
}

fileprivate func btTableHeight(_ model: BeatTableModel, tableWidth: CGFloat, font: NSFont) -> CGFloat {
	let rows = btRowHeights(model, tableWidth: tableWidth, font: font)
	return BTMetrics.marginTop + rows.reduce(0, +) + BTMetrics.border * CGFloat(rows.count + 1) + BTMetrics.marginBottom
}

// MARK: Cell view

fileprivate final class BeatTableCellView: NSTextView {
	var row = 0
	var col = 0
	weak var table: BeatTableView?
	
	override func becomeFirstResponder() -> Bool {
		let result = super.becomeFirstResponder()
		if result { table?.cellDidBecomeActive(self) }
		return result
	}
	
	override func resignFirstResponder() -> Bool {
		let result = super.resignFirstResponder()
		if result {
			table?.cellDidResignActive(self)
		}
		return result
	}
	
	var caretIsOnFirstLine: Bool {
		guard let lm = layoutManager, let tc = textContainer else { return true }
		let loc = selectedRange().location
		if loc == 0 || (string as NSString).length == 0 { return true }
		lm.ensureLayout(for: tc)
		let glyph = lm.glyphIndexForCharacter(at: min(loc, (string as NSString).length - 1))
		let caretRect = lm.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
		let firstRect = lm.lineFragmentRect(forGlyphAt: 0, effectiveRange: nil)
		return caretRect.minY <= firstRect.minY
	}
	
	var caretIsOnLastLine: Bool {
		guard let lm = layoutManager, let tc = textContainer else { return true }
		let length = (string as NSString).length
		let loc = selectedRange().location
		if length == 0 { return true }
		if loc >= length && (string as NSString).character(at: length - 1) == 10 { return true }
		lm.ensureLayout(for: tc)
		let glyph = lm.glyphIndexForCharacter(at: min(loc, length - 1))
		let caretRect = lm.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
		let lastRect = lm.lineFragmentRect(forGlyphAt: max(lm.numberOfGlyphs - 1, 0), effectiveRange: nil)
		return caretRect.minY >= lastRect.minY
	}
}

// MARK: Table view

fileprivate final class BeatTableView: NSView, NSTextViewDelegate {
	weak var host: BeatTextView?
	var model = BeatTableModel(rows: [[""]])
	/// The Markdown currently in the document for this table
	var sourceText = ""
	/// Range of the table in the document
	var tableRange = NSRange(location: 0, length: 0)
	var tableWidth: CGFloat = 400
	var font: NSFont = NSFont.userFixedPitchFont(ofSize: 12) ?? NSFont.systemFont(ofSize: 12)
	var textColor: NSColor = .textColor
	
	var cells: [[BeatTableCellView]] = []
	var rowHeights: [CGFloat] = []
	var activeCell: (row: Int, col: Int)? = nil
	var hovering = false
	
	let addRowButton = NSButton(title: "+", target: nil, action: nil)
	let addColumnButton = NSButton(title: "+", target: nil, action: nil)
	
	override var isFlipped: Bool { return true }
	
	init(host: BeatTextView) {
		self.host = host
		super.init(frame: .zero)
		
		for button in [addRowButton, addColumnButton] {
			button.isBordered = false
			button.wantsLayer = true
			button.layer?.cornerRadius = 3
			button.target = self
			button.isHidden = true
			button.toolTip = (button === addRowButton) ? "Add row" : "Add column"
			addSubview(button)
		}
		addRowButton.action = #selector(addRowAtEnd(_:))
		addColumnButton.action = #selector(addColumnAtEnd(_:))
	}
	
	required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
	
	var totalHeight: CGFloat {
		return BTMetrics.marginTop + rowHeights.reduce(0, +) + BTMetrics.border * CGFloat(rowHeights.count + 1) + BTMetrics.marginBottom
	}
	
	// MARK: Loading
	
	func load(text: String, lines: [String]) {
		sourceText = text
		let newModel = BeatTableModel.parse(lines)
		let sameShape = newModel.rows.count == model.rows.count && newModel.columnCount == model.columnCount && cells.count == model.rows.count
		model = newModel
		
		if sameShape {
			// Keep the cell views (and focus), just update the contents
			for (r, row) in cells.enumerated() {
				for (c, cell) in row.enumerated() where cell.string != model.rows[r][c] {
					cell.string = model.rows[r][c]
				}
			}
		} else {
			rebuildCells()
		}
		relayout()
	}
	
	func rebuildCells() {
		let focused = activeCell
		for row in cells { for cell in row { cell.removeFromSuperview() } }
		cells = []
		
		for (r, row) in model.rows.enumerated() {
			var rowCells: [BeatTableCellView] = []
			for (c, text) in row.enumerated() {
				let cell = BeatTableCellView(frame: NSRect(x: 0, y: 0, width: 100, height: 20))
				cell.row = r
				cell.col = c
				cell.table = self
				cell.delegate = self
				cell.isRichText = false
				cell.importsGraphics = false
				cell.allowsUndo = false
				cell.drawsBackground = false
				cell.isAutomaticQuoteSubstitutionEnabled = false
				cell.isAutomaticDashSubstitutionEnabled = false
				cell.isAutomaticTextReplacementEnabled = false
				cell.isVerticallyResizable = false
				cell.isHorizontallyResizable = false
				cell.textContainerInset = .zero
				cell.textContainer?.lineFragmentPadding = 0
				cell.textContainer?.widthTracksTextView = true
				cell.focusRingType = .none
				cell.font = font
				cell.textColor = textColor
				cell.insertionPointColor = host?.insertionPointColor ?? textColor
				cell.string = text
				addSubview(cell)
				rowCells.append(cell)
			}
			cells.append(rowCells)
		}
		
		if let focused, focused.row < cells.count, focused.col < cells[focused.row].count {
			focus(row: focused.row, col: focused.col, atEnd: true)
		}
	}
	
	func relayout() {
		for row in cells { for cell in row { cell.font = font; cell.textColor = textColor } }
		rowHeights = btRowHeights(model, tableWidth: tableWidth, font: font)
		let colWidth = btColumnWidth(tableWidth, columns: model.columnCount)
		
		var y = BTMetrics.marginTop + BTMetrics.border
		for (r, row) in cells.enumerated() {
			let h = r < rowHeights.count ? rowHeights[r] : 20
			for (c, cell) in row.enumerated() {
				let x = BTMetrics.border + CGFloat(c) * (colWidth + BTMetrics.border)
				cell.frame = NSRect(x: x + BTMetrics.paddingX, y: y + BTMetrics.paddingY,
									width: colWidth - BTMetrics.paddingX * 2, height: h - BTMetrics.paddingY * 2)
			}
			y += h + BTMetrics.border
		}
		
		let tableBottom = y
		let buttonColor = textColor.withAlphaComponent(0.08)
		let titleAttrs: [NSAttributedString.Key: Any] = [.foregroundColor: textColor.withAlphaComponent(0.55), .font: NSFont.systemFont(ofSize: 13)]
		for button in [addRowButton, addColumnButton] {
			button.layer?.backgroundColor = buttonColor.cgColor
			button.attributedTitle = NSAttributedString(string: "+", attributes: titleAttrs)
		}
		addRowButton.frame = NSRect(x: 0, y: tableBottom + 3, width: tableWidth, height: BTMetrics.addButtonSize)
		addColumnButton.frame = NSRect(x: tableWidth + 4, y: BTMetrics.marginTop, width: BTMetrics.addButtonSize, height: tableBottom - BTMetrics.marginTop)
		
		needsDisplay = true
	}
	
	// MARK: Drawing
	
	override func draw(_ dirtyRect: NSRect) {
		guard rowHeights.count > 0 else { return }
		let colWidth = btColumnWidth(tableWidth, columns: model.columnCount)
		let n = model.columnCount
		let gridWidth = BTMetrics.border * CGFloat(n + 1) + colWidth * CGFloat(n)
		let top = BTMetrics.marginTop
		let height = rowHeights.reduce(0, +) + BTMetrics.border * CGFloat(rowHeights.count + 1)
		
		// Header row
		textColor.withAlphaComponent(0.06).setFill()
		NSRect(x: 0, y: top, width: gridWidth, height: rowHeights[0] + BTMetrics.border * 2).fill()
		
		textColor.withAlphaComponent(0.2).setFill()
		
		// Horizontal lines
		var y = top
		NSRect(x: 0, y: y, width: gridWidth, height: BTMetrics.border).fill()
		for h in rowHeights {
			y += h + BTMetrics.border
			NSRect(x: 0, y: y, width: gridWidth, height: BTMetrics.border).fill()
		}
		
		// Vertical lines
		for c in 0...n {
			let x = CGFloat(c) * (colWidth + BTMetrics.border)
			NSRect(x: x, y: top, width: BTMetrics.border, height: height).fill()
		}
		
		// Active cell outline
		if let active = activeCell, active.row < rowHeights.count {
			var cellY = top
			for r in 0..<active.row { cellY += rowHeights[r] + BTMetrics.border }
			let cellX = CGFloat(active.col) * (colWidth + BTMetrics.border)
			let rect = NSRect(x: cellX, y: cellY, width: colWidth + BTMetrics.border * 2, height: rowHeights[active.row] + BTMetrics.border * 2)
			NSColor.controlAccentColor.withAlphaComponent(0.8).setStroke()
			let path = NSBezierPath(rect: rect.insetBy(dx: 0.75, dy: 0.75))
			path.lineWidth = 1.5
			path.stroke()
		}
	}
	
	// MARK: Hover
	
	override func updateTrackingAreas() {
		super.updateTrackingAreas()
		for area in trackingAreas { removeTrackingArea(area) }
		addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self, userInfo: nil))
	}
	
	override func mouseEntered(with event: NSEvent) { setHover(true) }
	override func mouseExited(with event: NSEvent) { setHover(false) }
	
	func setHover(_ value: Bool) {
		hovering = value
		let show = hovering || activeCell != nil
		addRowButton.isHidden = !show
		addColumnButton.isHidden = !show
	}
	
	// Clicking the grid lines or padding focuses the nearest cell
	override func mouseDown(with event: NSEvent) {
		let p = convert(event.locationInWindow, from: nil)
		let colWidth = btColumnWidth(tableWidth, columns: model.columnCount)
		let col = min(max(Int(p.x / (colWidth + BTMetrics.border)), 0), model.columnCount - 1)
		var y = BTMetrics.marginTop
		var row = rowHeights.count - 1
		for (r, h) in rowHeights.enumerated() {
			if p.y < y + h + BTMetrics.border { row = r; break }
			y += h + BTMetrics.border
		}
		focus(row: max(row, 0), col: col, atEnd: true)
	}
	
	// MARK: Focus
	
	func focus(row: Int, col: Int, atEnd: Bool) {
		guard row >= 0, row < cells.count, col >= 0, col < cells[row].count else { return }
		let cell = cells[row][col]
		window?.makeFirstResponder(cell)
		let length = (cell.string as NSString).length
		cell.setSelectedRange(NSRange(location: atEnd ? length : 0, length: 0))
		cell.scrollToVisible(cell.bounds)
	}
	
	func cellDidBecomeActive(_ cell: BeatTableCellView) {
		activeCell = (cell.row, cell.col)
		setHover(hovering)
		needsDisplay = true
	}
	
	func cellDidResignActive(_ cell: BeatTableCellView) {
		DispatchQueue.main.async { [weak self] in
			guard let self else { return }
			if let responder = self.window?.firstResponder as? BeatTableCellView, responder.table === self { return }
			self.activeCell = nil
			self.setHover(self.hovering)
			self.needsDisplay = true
		}
	}
	
	// MARK: Editing
	
	func textDidChange(_ notification: Notification) {
		guard let cell = notification.object as? BeatTableCellView,
			  cell.row < model.rows.count, cell.col < model.columnCount else { return }
		model.rows[cell.row][cell.col] = cell.string
		commit()
	}
	
	/// Writes the model back into the document
	func commit() {
		guard let host else { return }
		let newText = model.serialize()
		if newText != sourceText {
			host.replaceTableText(self, with: newText)
		}
		relayout()
		host.scheduleTableUpdate()
	}
	
	func setModel(_ newModel: BeatTableModel, focusRow: Int, focusCol: Int, atEnd: Bool = false) {
		model = newModel
		activeCell = (focusRow, focusCol)
		rebuildCells()
		commit()
		focus(row: focusRow, col: focusCol, atEnd: atEnd)
	}
	
	func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
		guard let cell = textView as? BeatTableCellView else { return false }
		let shift = NSApp.currentEvent?.modifierFlags.contains(.shift) ?? false
		
		switch commandSelector {
		case #selector(NSResponder.insertNewline(_:)):
			if shift {
				cell.insertText("\n", replacementRange: cell.selectedRange())
			} else {
				moveDown(from: cell, column: cell.col)
			}
			return true
			
		case #selector(NSResponder.insertLineBreak(_:)), #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)):
			cell.insertText("\n", replacementRange: cell.selectedRange())
			return true
			
		case #selector(NSResponder.insertTab(_:)):
			if cell.col + 1 < model.columnCount {
				focus(row: cell.row, col: cell.col + 1, atEnd: true)
			} else if cell.row + 1 < model.rows.count {
				focus(row: cell.row + 1, col: 0, atEnd: true)
			} else {
				var m = model
				m.rows.append(m.emptyRow())
				setModel(m, focusRow: m.rows.count - 1, focusCol: 0)
			}
			return true
			
		case #selector(NSResponder.insertBacktab(_:)):
			if cell.col > 0 {
				focus(row: cell.row, col: cell.col - 1, atEnd: true)
			} else if cell.row > 0 {
				focus(row: cell.row - 1, col: model.columnCount - 1, atEnd: true)
			}
			return true
			
		case #selector(NSResponder.moveUp(_:)):
			guard cell.caretIsOnFirstLine else { return false }
			if cell.row > 0 { focus(row: cell.row - 1, col: cell.col, atEnd: true) }
			else { host?.exitTable(self, below: false) }
			return true
			
		case #selector(NSResponder.moveDown(_:)):
			guard cell.caretIsOnLastLine else { return false }
			if cell.row + 1 < model.rows.count { focus(row: cell.row + 1, col: cell.col, atEnd: true) }
			else { host?.exitTable(self, below: true) }
			return true
			
		case #selector(NSResponder.cancelOperation(_:)):
			host?.exitTable(self, below: true)
			return true
			
		default:
			return false
		}
	}
	
	func moveDown(from cell: BeatTableCellView, column: Int) {
		if cell.row + 1 < model.rows.count {
			focus(row: cell.row + 1, col: column, atEnd: true)
		} else {
			var m = model
			m.rows.append(m.emptyRow())
			setModel(m, focusRow: m.rows.count - 1, focusCol: 0)
		}
	}
	
	// MARK: Menu
	
	func textView(_ view: NSTextView, menu: NSMenu, for event: NSEvent, at charIndex: Int) -> NSMenu? {
		guard let cell = view as? BeatTableCellView else { return menu }
		let items: [(String, Selector)] = [
			("Add Row Above", #selector(addRowAbove(_:))),
			("Add Row Below", #selector(addRowBelow(_:))),
			("Add Column Left", #selector(addColumnLeft(_:))),
			("Add Column Right", #selector(addColumnRight(_:))),
			("Delete Row", #selector(deleteRow(_:))),
			("Delete Column", #selector(deleteColumn(_:))),
			("Delete Table", #selector(deleteTable(_:)))
		]
		for item in menu.items where item.tag == BeatTableMenuItemTag { menu.removeItem(item) }
		var index = 0
		for (title, action) in items {
			let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
			item.target = self
			item.tag = BeatTableMenuItemTag
			item.representedObject = [cell.row, cell.col]
			menu.insertItem(item, at: index)
			index += 1
		}
		let separator = NSMenuItem.separator()
		separator.tag = BeatTableMenuItemTag
		menu.insertItem(separator, at: index)
		return menu
	}
	
	func position(_ sender: Any?) -> (Int, Int) {
		if let item = sender as? NSMenuItem, let pos = item.representedObject as? [Int], pos.count == 2 { return (pos[0], pos[1]) }
		if let active = activeCell { return (active.row, active.col) }
		return (model.rows.count - 1, 0)
	}
	
	@objc func addRowAtEnd(_ sender: Any?) {
		var m = model
		m.rows.append(m.emptyRow())
		setModel(m, focusRow: m.rows.count - 1, focusCol: 0)
	}
	
	@objc func addColumnAtEnd(_ sender: Any?) {
		var m = model
		m.rows = m.rows.map { $0 + [""] }
		setModel(m, focusRow: activeCell?.row ?? 0, focusCol: m.columnCount - 1)
	}
	
	@objc func addRowAbove(_ sender: Any?) {
		let (r, c) = position(sender)
		var m = model
		m.rows.insert(m.emptyRow(), at: r)
		setModel(m, focusRow: r, focusCol: c)
	}
	
	@objc func addRowBelow(_ sender: Any?) {
		let (r, c) = position(sender)
		var m = model
		m.rows.insert(m.emptyRow(), at: r + 1)
		setModel(m, focusRow: r + 1, focusCol: c)
	}
	
	@objc func addColumnLeft(_ sender: Any?) {
		let (r, c) = position(sender)
		var m = model
		m.rows = m.rows.map { row in var x = row; x.insert("", at: c); return x }
		setModel(m, focusRow: r, focusCol: c)
	}
	
	@objc func addColumnRight(_ sender: Any?) {
		let (r, c) = position(sender)
		var m = model
		m.rows = m.rows.map { row in var x = row; x.insert("", at: min(c + 1, x.count)); return x }
		setModel(m, focusRow: r, focusCol: c + 1)
	}
	
	@objc func deleteRow(_ sender: Any?) {
		let (r, c) = position(sender)
		if model.rows.count <= 1 { deleteTable(sender); return }
		var m = model
		m.rows.remove(at: r)
		setModel(m, focusRow: min(r, m.rows.count - 1), focusCol: c)
	}
	
	@objc func deleteColumn(_ sender: Any?) {
		let (r, c) = position(sender)
		if model.columnCount <= 1 { deleteTable(sender); return }
		var m = model
		m.rows = m.rows.map { row in var x = row; if c < x.count { x.remove(at: c) }; return x }
		setModel(m, focusRow: r, focusCol: max(c - 1, 0))
	}
	
	@objc func deleteTable(_ sender: Any?) {
		host?.deleteTable(self)
	}
}

// MARK: - Text view integration

public extension BeatTextView {
	
	fileprivate var tableViews: [BeatTableView] {
		get { return objc_getAssociatedObject(self, &BeatTableViewsKey) as? [BeatTableView] ?? [] }
		set { objc_setAssociatedObject(self, &BeatTableViewsKey, newValue, .OBJC_ASSOCIATION_RETAIN_NONATOMIC) }
	}
	
	fileprivate var tableHeightCache: [String: CGFloat] {
		get { return objc_getAssociatedObject(self, &BeatTableHeightCacheKey) as? [String: CGFloat] ?? [:] }
		set { objc_setAssociatedObject(self, &BeatTableHeightCacheKey, newValue, .OBJC_ASSOCIATION_RETAIN_NONATOMIC) }
	}
	
	/// `true` while a table view writes its text into the document
	fileprivate var isWritingTable: Bool {
		get { return (objc_getAssociatedObject(self, &BeatTableWritingKey) as? Bool) ?? false }
		set { objc_setAssociatedObject(self, &BeatTableWritingKey, newValue, .OBJC_ASSOCIATION_RETAIN_NONATOMIC) }
	}
	
	/// `true` when the user is typing in a table (or a table is writing into the document).
	/// The main text view must not scroll to its own hidden caret then.
	@objc var isEditingTable: Bool {
		if isWritingTable { return true }
		if let cell = window?.firstResponder as? BeatTableCellView, cell.table?.host === self { return true }
		if let embed = window?.firstResponder as? ViralEmbedView, embed.host === self { return true }
		return false
	}
	
	/// Table start position and cell to focus once the table view exists
	fileprivate var pendingTableFocus: [Int]? {
		get { return objc_getAssociatedObject(self, &BeatTablePendingFocusKey) as? [Int] }
		set { objc_setAssociatedObject(self, &BeatTablePendingFocusKey, newValue, .OBJC_ASSOCIATION_RETAIN_NONATOMIC) }
	}
	
	fileprivate var tableFont: NSFont {
		let font = self.font ?? NSFont.userFixedPitchFont(ofSize: 12) ?? NSFont.systemFont(ofSize: 12)
		// The text view font can be the bold heading font, use the regular style
		return NSFontManager.shared.convert(font, toNotHaveTrait: [.boldFontMask, .italicFontMask])
	}
	
	/// Tables fill the full text width
	fileprivate var tableWidth: CGFloat {
		guard let tc = textContainer else { return 400 }
		return floor(tc.size.width - tc.lineFragmentPadding * 2)
	}
	
	// MARK: Finding tables
	
	fileprivate struct BTBlock {
		var range: NSRange
		var lines: [String]
	}
	
	fileprivate var blockCache: ViralBlockCache {
		if let cache = objc_getAssociatedObject(self, &ViralBlockCacheKey) as? ViralBlockCache { return cache }
		let cache = ViralBlockCache()
		objc_setAssociatedObject(self, &ViralBlockCacheKey, cache, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
		return cache
	}
	
	/// Tables in the document, scanned again only when the text changed
	fileprivate func tableBlocks() -> [BTBlock] {
		let cache = blockCache
		let length = (self.string as NSString).length
		if cache.tableKey.version == cache.version && cache.tableKey.length == length, let blocks = cache.tables as? [BTBlock] { return blocks }
		let blocks = scanTableBlocks()
		cache.tables = blocks
		cache.tableKey = (cache.version, length)
		return blocks
	}
	
	/// Finds tables from the text itself (the parser can lag behind right after an edit)
	fileprivate func scanTableBlocks() -> [BTBlock] {
		let ns = self.string as NSString
		var blocks: [BTBlock] = []
		var start = -1
		var end = 0
		var lines: [String] = []
		var location = 0
		
		while location < ns.length {
			let lineRange = ns.lineRange(for: NSRange(location: location, length: 0))
			if lineRange.length == 0 { break }
			var content = lineRange
			if content.length > 0 && ns.character(at: NSMaxRange(content) - 1) == 10 { content.length -= 1 }
			let line = ns.substring(with: content)
			
			if BeatTableModel.isRow(line) {
				if start < 0 { start = content.location; lines = [] }
				lines.append(line)
				end = NSMaxRange(content)
			} else if start >= 0 {
				blocks.append(BTBlock(range: NSRange(location: start, length: end - start), lines: lines))
				start = -1
			}
			location = NSMaxRange(lineRange)
		}
		if start >= 0 { blocks.append(BTBlock(range: NSRange(location: start, length: end - start), lines: lines)) }
		
		return blocks
	}
	
	/// Table lines starting at given location
	fileprivate func tableLines(at location: Int) -> [String] {
		let ns = self.string as NSString
		var lines: [String] = []
		var loc = location
		while loc < ns.length {
			let lineRange = ns.lineRange(for: NSRange(location: loc, length: 0))
			if lineRange.length == 0 { break }
			var content = lineRange
			if content.length > 0 && ns.character(at: NSMaxRange(content) - 1) == 10 { content.length -= 1 }
			let line = ns.substring(with: content)
			if !BeatTableModel.isRow(line) { break }
			lines.append(line)
			loc = NSMaxRange(lineRange)
		}
		return lines
	}
	
	// MARK: BeatTableHost
	
	@objc func tableHeightAtLocation(_ location: Int) -> CGFloat {
		if let embedHeight = embedHeightAtLocation(location) { return embedHeight }
		let strings = tableLines(at: location)
		if strings.isEmpty { return 0 }
		
		let width = tableWidth
		let key = strings.joined(separator: "\n") + "#\(width)#\(tableFont.pointSize)"
		if let cached = tableHeightCache[key] { return cached }
		
		let height = btTableHeight(BeatTableModel.parse(strings), tableWidth: width, font: tableFont)
		var cache = tableHeightCache
		if cache.count > 200 { cache.removeAll() }
		cache[key] = height
		tableHeightCache = cache
		return height
	}
	
	@objc func tableLayoutDidChange() {
		scheduleTableUpdate()
	}
	
	fileprivate func scheduleTableUpdate() {
		installTableObserversIfNeeded()
		if (objc_getAssociatedObject(self, &BeatTableUpdateScheduledKey) as? Bool) == true { return }
		objc_setAssociatedObject(self, &BeatTableUpdateScheduledKey, true, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
		DispatchQueue.main.async { [weak self] in
			guard let self else { return }
			objc_setAssociatedObject(self, &BeatTableUpdateScheduledKey, false, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
			self.updateTableViews()
		}
	}
	
	fileprivate func installTableObserversIfNeeded() {
		if (objc_getAssociatedObject(self, &BeatTableObserversKey) as? Bool) == true { return }
		objc_setAssociatedObject(self, &BeatTableObserversKey, true, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
		
		NotificationCenter.default.addObserver(forName: NSText.didChangeNotification, object: self, queue: .main) { [weak self] _ in
			self?.scheduleTableUpdate()
		}
		NotificationCenter.default.addObserver(forName: NSTextView.didChangeSelectionNotification, object: self, queue: .main) { [weak self] _ in
			self?.caretMovedIntoTableIfNeeded()
		}
		if let storage = textStorage {
			NotificationCenter.default.addObserver(forName: NSTextStorage.didProcessEditingNotification, object: storage, queue: nil) { [weak self] note in
				guard let storage = note.object as? NSTextStorage, storage.editedMask.contains(.editedCharacters) else { return }
				self?.blockCache.version += 1
			}
		}
		if let clip = enclosingScrollView?.contentView {
			clip.postsBoundsChangedNotifications = true
			NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: clip, queue: .main) { [weak self] _ in
				self?.schedulePlayerCheck()
			}
		}
	}
	
	/// Video players far outside the visible area are closed (they show their thumbnail instead). Keeps scrolling smooth.
	fileprivate func schedulePlayerCheck() {
		if (objc_getAssociatedObject(self, &ViralPlayerCheckKey) as? Bool) == true { return }
		objc_setAssociatedObject(self, &ViralPlayerCheckKey, true, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
		DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
			guard let self else { return }
			objc_setAssociatedObject(self, &ViralPlayerCheckKey, false, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
			let visible = self.visibleRect
			let keep = visible.insetBy(dx: 0, dy: -visible.height * 1.5)
			for view in self.embedViews where !view.frame.intersects(keep) {
				view.suspendPlayers()
			}
		}
	}
	
	// MARK: Placing table views
	
	/// True when the text at this location is inside a folded section
	fileprivate func isFolded(_ location: Int) -> Bool {
		guard let storage = textStorage, location < storage.length else { return false }
		return storage.attribute(NSAttributedString.Key("BeatFolded"), at: location, effectiveRange: nil) != nil
	}
	
	fileprivate func updateTableViews() {
		guard let lm = layoutManager, let tc = textContainer else { return }
		let blocks = tableBlocks()
		var views = tableViews
		
		
		// Reuse views for tables that still exist (matched by position), so editing and focus survive updates
		var unused = views
		var ordered: [BeatTableView] = []
		for block in blocks {
			if let index = unused.indices.min(by: { abs(unused[$0].tableRange.location - block.range.location) < abs(unused[$1].tableRange.location - block.range.location) }) {
				ordered.append(unused.remove(at: index))
			} else {
				let view = BeatTableView(host: self)
				addSubview(view)
				ordered.append(view)
			}
		}
		for view in unused {
			// A table that no longer exists in the text (undo, cut) is dropped, even if one of its cells has focus
			if let responder = window?.firstResponder as? BeatTableCellView, responder.table === view {
				// Mid-write the text can be briefly out of step, so keep the view until the write is done
				if isWritingTable { ordered.append(view); continue }
				window?.makeFirstResponder(self)
			}
			view.removeFromSuperview()
		}
		views = ordered
		
		let width = tableWidth
		let ns = self.string as NSString
		
		for (i, block) in blocks.enumerated() {
			let view = views[i]
			
			view.tableRange = block.range
			// Only lay the cells out again when something that affects them changed (this runs on every layout pass)
			let font = tableFont
			let color = self.textColor ?? .textColor
			let styleChanged = view.tableWidth != width || view.font != font || view.textColor != color
			view.font = font
			view.textColor = color
			view.tableWidth = width
			
			let text = ns.substring(with: block.range)
			if text != view.sourceText || view.cells.isEmpty {
				view.load(text: text, lines: block.lines)
			} else if styleChanged {
				view.relayout()
			}
			
			let glyph = lm.glyphIndexForCharacter(at: block.range.location)
			let lineRect = lm.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
			let origin = textContainerOrigin
			let frame = NSRect(x: origin.x + tc.lineFragmentPadding,
							   y: origin.y + lineRect.minY,
							   width: width + BTMetrics.addButtonSize + 8,
							   height: view.totalHeight)
			if view.frame != frame { view.frame = frame }
			let folded = isFolded(block.range.location)
			if view.isHidden != folded { view.isHidden = folded }
		}
		
		tableViews = views
		updateEmbedViews()
		updateSaveAsButton()
		
		// Focus a newly inserted table
		if let pending = pendingTableFocus, let view = views.first(where: { $0.tableRange.location == pending[0] }) {
			pendingTableFocus = nil
			view.focus(row: pending[1], col: pending[2], atEnd: true)
		}
	}
	
	// MARK: Editing the document
	
	/// Writes table text into the document. Only the lines that changed are replaced (like normal typing), which keeps the parser happy.
	fileprivate func replaceTableText(_ view: BeatTableView, with text: String) {
		guard let textActions = editorDelegate?.textActions else { return }
		let ns = self.string as NSString
		// Only write if the text under the view is still the table it shows, never over other text
		guard NSMaxRange(view.tableRange) <= ns.length, ns.substring(with: view.tableRange) == view.sourceText else { return }
		
		let selection = self.selectedRange()
		let activeCell = window?.firstResponder as? BeatTableCellView
		let cellSelection = activeCell?.selectedRange()
		
		let range = view.tableRange
		let old = ns.substring(with: range).components(separatedBy: "\n")
		let new = text.components(separatedBy: "\n")
		
		// Start position of each old line
		var starts: [Int] = []
		var pos = range.location
		for line in old { starts.append(pos); pos += (line as NSString).length + 1 }
		
		var prefix = 0
		while prefix < min(old.count, new.count) && old[prefix] == new[prefix] { prefix += 1 }
		var suffix = 0
		while suffix < min(old.count, new.count) - prefix && old[old.count - 1 - suffix] == new[new.count - 1 - suffix] { suffix += 1 }
		
		view.sourceText = text
		
		// Park the hidden main caret at the start of this table. If the caret was somewhere below (like in a later table),
		// any scrolling to it while the document updates would jump down the document.
		isWritingTable = true
		defer { isWritingTable = false }
		if window?.firstResponder !== self {
			self.setSelectedRange(NSRange(location: range.location, length: 0))
		}
		let heightBefore = tableHeightAtLocation(range.location)
		
		if old.count == new.count {
			for i in stride(from: old.count - 1 - suffix, through: prefix, by: -1) where old[i] != new[i] {
				textActions.replace(NSRange(location: starts[i], length: (old[i] as NSString).length), with: new[i])
			}
		} else {
			let oldMid = Array(old[prefix..<(old.count - suffix)])
			let newMid = Array(new[prefix..<(new.count - suffix)])
			
			if oldMid.count > 0 {
				let first = starts[prefix]
				let lastIndex = old.count - suffix - 1
				let end = starts[lastIndex] + (old[lastIndex] as NSString).length
				if newMid.count > 0 {
					textActions.replace(NSRange(location: first, length: end - first), with: newMid.joined(separator: "\n"))
				} else if prefix > 0 {
					// Remove whole lines, including the line break before them
					textActions.replace(NSRange(location: first - 1, length: end - first + 1), with: "")
				} else {
					// Remove whole lines at the start of the table, including the line break after them
					textActions.replace(NSRange(location: first, length: end - first + 1), with: "")
				}
			} else if prefix < old.count {
				// Insert new lines before line `prefix`
				textActions.replace(NSRange(location: starts[prefix], length: 0), with: newMid.joined(separator: "\n") + "\n")
			} else {
				// Append new lines to the end of the table
				textActions.replace(NSRange(location: NSMaxRange(range), length: 0), with: "\n" + newMid.joined(separator: "\n"))
			}
		}
		
		let delta = (text as NSString).length - range.length
		view.tableRange.length = (text as NSString).length
		
		// The table height lives on its first line. Lay it out again only when the height changed:
		// it also re-lays out everything below the table, which is slow in long documents.
		if range.location < (self.string as NSString).length && tableHeightAtLocation(range.location) != heightBefore {
			layoutManager?.invalidateLayout(forCharacterRange: NSRange(location: range.location, length: 1), actualCharacterRange: nil)
		}
		
		// Keep typing in the cell even if something moved focus while the document was updated
		if let activeCell, let cellSelection, window?.firstResponder !== activeCell {
			window?.makeFirstResponder(activeCell)
			activeCell.setSelectedRange(cellSelection)
		}
		
		// Keep the main caret where it was if the main view is the one being edited
		if activeCell == nil && selection.location > range.location {
			let loc = min(max(selection.location + delta, 0), (self.string as NSString).length)
			self.setSelectedRange(NSRange(location: loc, length: 0))
		}
	}
	
	fileprivate func deleteTable(_ view: BeatTableView) {
		guard let textActions = editorDelegate?.textActions else { return }
		let ns = self.string as NSString
		var range = view.tableRange
		guard NSMaxRange(range) <= ns.length else { return }
		if NSMaxRange(range) < ns.length { range.length += 1 }
		
		// Remove the view first, so nothing can move the caret back into it (which kept the table alive before)
		tableViews.removeAll { $0 === view }
		window?.makeFirstResponder(self)
		view.removeFromSuperview()
		
		isWritingTable = true
		textActions.replace(range, with: "")
		isWritingTable = false
		self.setSelectedRange(NSRange(location: min(range.location, (self.string as NSString).length), length: 0))
		scheduleTableUpdate()
	}
	
	/// Moves the caret out of the table into the script
	fileprivate func exitTable(_ view: BeatTableView, below: Bool) {
		guard let textActions = editorDelegate?.textActions else { return }
		window?.makeFirstResponder(self)
		
		let range = view.tableRange
		if below {
			let end = NSMaxRange(range)
			let length = (self.string as NSString).length
			if end >= length {
				// Table is at the end of the document, add room below it
				textActions.replace(NSRange(location: length, length: 0), with: "\n\n")
			}
			let ns = self.string as NSString
			var target = min(end + 1, ns.length)
			// Skip a blank line right after the table
			if target < ns.length && ns.character(at: target) == 10 { target += 1 }
			self.setSelectedRange(NSRange(location: min(target, ns.length), length: 0))
		} else {
			if range.location == 0 {
				textActions.replace(NSRange(location: 0, length: 0), with: "\n")
				self.setSelectedRange(NSRange(location: 0, length: 0))
			} else {
				self.setSelectedRange(NSRange(location: range.location - 1, length: 0))
			}
		}
		scrollRangeToVisible(self.selectedRange())
	}
	
	/// If the caret lands in hidden table text (arrow keys etc.), move into the table view instead
	fileprivate func caretMovedIntoTableIfNeeded() {
		guard window?.firstResponder === self, !isWritingTable else { return }
		let selection = self.selectedRange()
		guard selection.length == 0 else { return }
		
		for view in embedViews {
			let range = view.blockRange
			if selection.location >= range.location && selection.location <= NSMaxRange(range) && range.length > 0 {
				let atStart = selection.location == range.location
				DispatchQueue.main.async { [weak self] in
					guard let self, self.window?.firstResponder === self, !self.isWritingTable,
						  self.selectedRange().location == selection.location else { return }
					view.activate(atEnd: !atStart)
				}
				return
			}
		}
		
		for view in tableViews {
			let range = view.tableRange
			if selection.location >= range.location && selection.location <= NSMaxRange(range) && range.length > 0 {
				let row = selection.location == range.location ? 0 : view.model.rows.count - 1
				DispatchQueue.main.async { [weak self] in
					// Only if the caret is still there and nobody is typing in a table
					guard let self, self.window?.firstResponder === self, !self.isWritingTable,
						  self.selectedRange().location == selection.location else { return }
					view.focus(row: row, col: 0, atEnd: true)
				}
				return
			}
		}
	}
	
	/// Inserts a new table at the caret. Uses the current line if it's empty.
	fileprivate func insertTable(columns: Int, bodyRows: Int, replacing lineRange: NSRange? = nil) {
		guard let textActions = editorDelegate?.textActions else { return }
		let ns = self.string as NSString
		
		let cols = min(max(columns, 1), 12)
		let body = min(max(bodyRows, 1), 50)
		let model = BeatTableModel(rows: Array(repeating: Array(repeating: "", count: cols), count: body + 1))
		var text = model.serialize()
		
		var range: NSRange
		if let lineRange {
			range = lineRange
		} else {
			let current = ns.lineRange(for: NSRange(location: self.selectedRange().location, length: 0))
			var lineOnly = current
			if lineOnly.length > 0 && ns.character(at: NSMaxRange(lineOnly) - 1) == 10 { lineOnly.length -= 1 }
			if lineOnly.length == 0 {
				range = lineOnly
			} else {
				range = NSRange(location: NSMaxRange(lineOnly), length: 0)
				text = "\n\n" + text
			}
		}
		
		// Make sure there's a line after the table
		let after = NSMaxRange(range)
		if after >= ns.length || ns.character(at: after) != 10 { text += "\n" }
		
		textActions.replace(range, with: text)
		
		let tableStart = range.location + (text.hasPrefix("\n\n") ? 2 : 0)
		pendingTableFocus = [tableStart, 0, 0]
		scheduleTableUpdate()
	}
	
	// MARK: Key handling (main text view)
	
	/// Called from `keyDown:` before default handling. Returns `true` if the event was handled.
	@objc func handleTableKeyDown(_ event: NSEvent) -> Bool {
		installTableObserversIfNeeded()
		if self.hasMarkedText() { return false }
		
		var flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
		flags.remove(.capsLock)
		flags.remove(.numericPad)
		flags.remove(.function)
		
		let selection = self.selectedRange()
		
		// Return on the title page `Save As:` line saves under that name (it never saves by itself while typing)
		if (event.keyCode == 36 || event.keyCode == 76) && flags.isEmpty && selection.length == 0,
		   let line = saveAsLineRange, selection.location >= line.location && selection.location <= NSMaxRange(line) {
			performSaveAs()
			return true
		}
		
		// Return on a `/table` line inserts a table
		if (event.keyCode == 36 || event.keyCode == 76) && flags.isEmpty && selection.length == 0 {
			if insertTitlePageFromCommand() { return true }
			if insertTableFromCommand() { return true }
			if insertEmbedFromCommand() { return true }
		}
		
		// Never type into hidden image text
		if selection.length == 0 {
			for view in embedViews where selection.location > view.blockRange.location && selection.location <= NSMaxRange(view.blockRange) {
				view.activate(atEnd: true)
				return true
			}
		}
		
		// Backspace at the start of a line right after a table or images selects the block instead of joining the lines
		if event.keyCode == 51 && selection.length == 0 && selection.location > 0 && flags.subtracting(.shift).isEmpty {
			let ns = self.string as NSString
			let lineEnd = ns.lineRange(for: NSRange(location: selection.location, length: 0))
			let lineHasText = selection.location < ns.length && ns.character(at: selection.location) != 10 && lineEnd.length > 0
			if ns.character(at: selection.location - 1) == 10 && lineHasText {
				let previous = selection.location - 1
				for view in embedViews where NSMaxRange(view.blockRange) == previous {
					view.activate(atEnd: true)
					return true
				}
				for view in tableViews where NSMaxRange(view.tableRange) == previous {
					let lastRow = max(view.model.rows.count - 1, 0)
					view.focus(row: lastRow, col: max(view.model.columnCount - 1, 0), atEnd: true)
					return true
				}
			}
		}
		
		// Forward delete at the end of a line right before a block
		if event.keyCode == 117 && selection.length == 0 {
			let ns = self.string as NSString
			if selection.location < ns.length && ns.character(at: selection.location) == 10 {
				let next = selection.location + 1
				for view in embedViews where view.blockRange.location == next {
					view.activate(atEnd: false)
					return true
				}
				for view in tableViews where view.tableRange.location == next {
					view.focus(row: 0, col: 0, atEnd: false)
					return true
				}
			}
		}
		
		// Never type into hidden table text
		if selection.length == 0 {
			for view in tableViews where selection.location > view.tableRange.location && selection.location <= NSMaxRange(view.tableRange) {
				view.focus(row: 0, col: 0, atEnd: true)
				return true
			}
		}
		
		return false
	}
	
	/// Called from `keyDown:` after default handling
	@objc func tableDidProcessKeyDown(_ event: NSEvent) {
		scheduleTableUpdate()
	}
	
	/// `/title` adds a title page at the top of the document (or jumps to the one that's there)
	fileprivate func insertTitlePageFromCommand() -> Bool {
		let ns = self.string as NSString
		var lineRange = ns.lineRange(for: NSRange(location: self.selectedRange().location, length: 0))
		let fullLine = lineRange
		if lineRange.length > 0 && ns.character(at: NSMaxRange(lineRange) - 1) == 10 { lineRange.length -= 1 }
		let line = ns.substring(with: lineRange).trimmingCharacters(in: .whitespaces).lowercased()
		guard line == "/title", let textActions = editorDelegate?.textActions else { return false }
		
		textActions.replace(fullLine, with: "")
		
		if (editorDelegate?.parser.lines.firstObject as? Line)?.isTitlePage() == true {
			self.setSelectedRange(NSRange(location: 0, length: 0))
			scrollRangeToVisible(NSRange(location: 0, length: 0))
			return true
		}
		
		textActions.replace(NSRange(location: 0, length: 0), with: ViralTitlePageTemplate.text())
		self.setSelectedRange(NSRange(location: 7, length: 0))
		scrollRangeToVisible(NSRange(location: 0, length: 0))
		return true
	}
	
	fileprivate func insertTableFromCommand() -> Bool {
		let ns = self.string as NSString
		var lineRange = ns.lineRange(for: NSRange(location: self.selectedRange().location, length: 0))
		if lineRange.length > 0 && ns.character(at: NSMaxRange(lineRange) - 1) == 10 { lineRange.length -= 1 }
		let line = ns.substring(with: lineRange).trimmingCharacters(in: .whitespaces).lowercased()
		guard line.hasPrefix("/table") else { return false }
		
		let rest = line.dropFirst(6).trimmingCharacters(in: .whitespaces)
		var cols = 3
		var body = 2
		
		if rest.count > 0 {
			let parts = rest.components(separatedBy: "x").map { $0.trimmingCharacters(in: .whitespaces) }
			guard let c = Int(parts[0]) else { return false }
			cols = c
			if parts.count > 1 {
				guard let b = Int(parts[1]) else { return false }
				body = b
			}
		}
		
		insertTable(columns: cols, bodyRows: body, replacing: lineRange)
		return true
	}
	
	// MARK: Context menu (main text view)
	
	@objc func addTableMenuItems(_ menu: NSMenu) {
		for item in menu.items where item.tag == BeatTableMenuItemTag {
			menu.removeItem(item)
		}
		let item = NSMenuItem(title: "Insert Table", action: #selector(tableInsert(_:)), keyEquivalent: "")
		item.tag = BeatTableMenuItemTag
		item.target = self
		menu.insertItem(item, at: 0)
		let imageItem = NSMenuItem(title: "Insert Image…", action: #selector(viralInsertImage(_:)), keyEquivalent: "")
		imageItem.tag = BeatTableMenuItemTag
		imageItem.target = self
		menu.insertItem(imageItem, at: 1)
		let carouselItem = NSMenuItem(title: "Insert Carousel", action: #selector(viralInsertCarousel(_:)), keyEquivalent: "")
		carouselItem.tag = BeatTableMenuItemTag
		carouselItem.target = self
		menu.insertItem(carouselItem, at: 2)
		let separator = NSMenuItem.separator()
		separator.tag = BeatTableMenuItemTag
		menu.insertItem(separator, at: 3)
	}
	
	@objc func tableInsert(_ sender: Any?) {
		insertTable(columns: 3, bodyRows: 2)
	}
}


// MARK: - Images, videos and carousels
/*
 
 Images are stored in the document settings (base64, key `ViralImages`) and referenced from the text:
 
 ![image](viral:ID 50 r)                      an image, 50% of the text width, rounded corners
 ![video](viral:URL^THUMB 50)                 a video link (YouTube, Vimeo, Instagram, Facebook), with a thumbnail for print
 ![carousel](viral:ID1,ID2,URL^THUMB h40 r)   a carousel, 40% of the text width high
 
 Consecutive image and video lines are laid out side by side when they fit, otherwise they wrap to the next row.
 Like tables, the text is hidden in the editor and a view is drawn on top of it.
 
 Paste or drop images or video links anywhere, or type `/image` or `/carousel` and press Return.
 
 */

fileprivate let ViralImagesKey = "ViralImages"
fileprivate let ViralVideosReloadNotification = Notification.Name("ViralVideosReload")
fileprivate var ViralEmbedViewsKey: UInt8 = 0
fileprivate var ViralPendingEmbedFocusKey: UInt8 = 0

fileprivate enum EMetrics {
	static let marginTop: CGFloat = 8
	static let marginBottom: CGFloat = 14
	static let handle: CGFloat = 12
	static let fade: CGFloat = 56
}

fileprivate enum EmbedKind {
	case image, video, carousel
	var isGroupItem: Bool { return self != .carousel }
}

fileprivate struct EmbedLine {
	var kind: EmbedKind
	var ids: [String]
	var width: Int
	/// Carousel height in percent of the text width
	var height: Int = 40
	var rounded: Bool = false
	
	static let imagePrefix = "![image](viral:"
	static let videoPrefix = "![video](viral:"
	static let carouselPrefix = "![carousel](viral:"
	
	static func parse(_ string: String) -> EmbedLine? {
		let t = string.trimmingCharacters(in: .whitespaces)
		guard t.hasSuffix(")") else { return nil }
		let kind: EmbedKind
		let prefix: String
		if t.hasPrefix(imagePrefix) { kind = .image; prefix = imagePrefix }
		else if t.hasPrefix(videoPrefix) { kind = .video; prefix = videoPrefix }
		else if t.hasPrefix(carouselPrefix) { kind = .carousel; prefix = carouselPrefix }
		else { return nil }
		guard t.count > prefix.count else { return nil }
		
		let inner = String(t.dropFirst(prefix.count).dropLast())
		let parts = inner.components(separatedBy: " ")
		let ids = (parts.first ?? "").components(separatedBy: ",")
			.map { $0.trimmingCharacters(in: .whitespaces) }
			.filter { !$0.isEmpty }
		var width = 100
		var height = 40
		var rounded = false
		for part in parts.dropFirst() {
			if part == "r" { rounded = true }
			else if part.hasPrefix("h"), let h = Int(part.dropFirst()), h > 0 { height = min(max(h, 10), 150) }
			else if let w = Int(part), w > 0 { width = w }
		}
		return EmbedLine(kind: kind, ids: ids, width: min(max(width, 5), 100), height: height, rounded: rounded)
	}
	
	var text: String {
		let prefix: String
		switch kind {
		case .image: prefix = EmbedLine.imagePrefix
		case .video: prefix = EmbedLine.videoPrefix
		case .carousel: prefix = EmbedLine.carouselPrefix
		}
		let size = (kind == .carousel) ? "h\(height)" : "\(width)"
		return prefix + ids.joined(separator: ",") + " " + size + (rounded ? " r" : "") + ")"
	}
	
	static func cornerRadius(_ rect: NSRect) -> CGFloat {
		return min(12, min(rect.width, rect.height) * 0.1)
	}
}

// MARK: Media entries

/// An entry is either an image ID, or a video URL optionally followed by `^` and a thumbnail image ID
fileprivate enum ViralMedia {
	static func isVideo(_ entry: String) -> Bool { return entry.contains("://") }
	
	static func encode(_ url: String) -> String {
		return url.replacingOccurrences(of: " ", with: "%20")
			.replacingOccurrences(of: ",", with: "%2C")
			.replacingOccurrences(of: "(", with: "%28")
			.replacingOccurrences(of: ")", with: "%29")
			.replacingOccurrences(of: "^", with: "%5E")
	}
	
	/// The link part of an entry. It stays percent-encoded, which is still a valid address and never turns `%2C` in a pasted link into something else.
	static func url(_ entry: String) -> String {
		return entry.components(separatedBy: "^").first ?? entry
	}
	
	static func thumbnail(_ entry: String) -> String? {
		let parts = entry.components(separatedBy: "^")
		return parts.count > 1 && !parts[1].isEmpty ? parts[1] : nil
	}
	
	static func make(url: String, thumbnail: String?) -> String {
		return encode(url) + (thumbnail.map { "^" + $0 } ?? "")
	}
}

// MARK: Video links

fileprivate enum ViralVideo {
	struct Info {
		var embed: String
		/// Height divided by width
		var aspect: CGFloat
		var provider: String
	}
	
	static func info(_ string: String) -> Info? {
		let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
		guard !trimmed.contains(" "), !trimmed.contains("\n"),
			  let url = URL(string: trimmed), let host = url.host?.lowercased(),
			  url.scheme == "https" || url.scheme == "http"
		else { return nil }
		let parts = url.path.split(separator: "/").map(String.init)
		
		if host == "youtu.be" || host.hasSuffix("youtube.com") || host.hasSuffix("youtube-nocookie.com") {
			var id: String? = nil
			var vertical = false
			if host == "youtu.be" { id = parts.first }
			else if parts.first == "watch" { id = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "v" })?.value }
			else if parts.first == "shorts", parts.count > 1 { id = parts[1]; vertical = true }
			else if ["embed", "live", "v"].contains(parts.first ?? ""), parts.count > 1 { id = parts[1] }
			guard let id, !id.isEmpty else { return nil }
			return Info(embed: "https://www.youtube.com/embed/\(id)?playsinline=1&rel=0", aspect: vertical ? 16.0 / 9.0 : 9.0 / 16.0, provider: "YouTube")
		}
		
		if host.hasSuffix("vimeo.com") {
			guard let id = parts.last(where: { Int($0) != nil }) else { return nil }
			return Info(embed: "https://player.vimeo.com/video/\(id)", aspect: 9.0 / 16.0, provider: "Vimeo")
		}
		
		if host.hasSuffix("instagram.com") {
			guard parts.count >= 2, ["p", "reel", "reels", "tv"].contains(parts[0]) else { return nil }
			let kind = (parts[0] == "reels") ? "reel" : parts[0]
			return Info(embed: "https://www.instagram.com/\(kind)/\(parts[1])/embed/", aspect: (kind == "reel") ? 16.0 / 9.0 : 1.25, provider: "Instagram")
		}
		
		if host.hasSuffix("facebook.com") || host == "fb.watch" {
			let isVideo = trimmed.contains("/videos/") || trimmed.contains("/watch") || trimmed.contains("/reel") || host == "fb.watch" || trimmed.contains("/share/v/") || trimmed.contains("/share/r/")
			guard isVideo else { return nil }
			let encoded = trimmed.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? trimmed
			let vertical = trimmed.contains("/reel") || trimmed.contains("/share/r/")
			return Info(embed: "https://www.facebook.com/plugins/video.php?href=\(encoded)&show_text=false", aspect: vertical ? 16.0 / 9.0 : 9.0 / 16.0, provider: "Facebook")
		}
		
		return nil
	}
	
	/// Matches the rules used for printing (see `BeatRenderer`)
	static func aspect(_ url: String) -> CGFloat {
		return info(url)?.aspect ?? 9.0 / 16.0
	}
}

/// A web view for players: no download items in its menu
fileprivate final class ViralWebView: WKWebView {
	override func willOpenMenu(_ menu: NSMenu, with event: NSEvent) {
		for item in menu.items {
			let identifier = item.identifier?.rawValue.lowercased() ?? ""
			if identifier.contains("download") || item.title.lowercased().contains("download") {
				menu.removeItem(item)
			}
		}
		super.willOpenMenu(menu, with: event)
	}
}

fileprivate enum ViralWeb {
	static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.5 Safari/605.1.15"
	static let baseURL = URL(string: "https://inhousetv.us/")!
	
	static func configuration() -> WKWebViewConfiguration {
		let configuration = WKWebViewConfiguration()
		configuration.websiteDataStore = .default()
		configuration.mediaTypesRequiringUserActionForPlayback = []
		if #available(macOS 12.3, *) { configuration.preferences.isElementFullscreenEnabled = true }
		return configuration
	}
	
	static func makeView() -> WKWebView {
		let view = ViralWebView(frame: .zero, configuration: configuration())
		view.customUserAgent = userAgent
		view.underPageBackgroundColor = .black
		view.wantsLayer = true
		view.layer?.backgroundColor = NSColor.black.cgColor
		return view
	}
	
	/// Players draw their controls for the size they think they are. Rendering them as if they were bigger keeps the controls small.
	static func fitZoom(_ view: WKWebView, url: String? = nil) {
		let width = view.bounds.width
		guard width > 1 else { return }
		// Instagram and Facebook embeds are cards with a maximum width, so they are scaled to fit that width
		let provider = url.flatMap { ViralVideo.info($0)?.provider } ?? ""
		// Instagram is shown with a plain video player, which doesn't need scaling
		let reference: CGFloat = (provider == "Facebook") ? 560 : 720
		let zoom = (provider == "Instagram") ? 1.0 : min(1.0, max(0.3, width / reference))
		if abs(view.pageZoom - zoom) > 0.01 { view.pageZoom = zoom }
	}
	
	/// Finds the video (or photo) address in an Instagram embed page
	static let instagramExtractScript = #"""
	(function(){
		var h = document.documentElement.innerHTML;
		function grab(key) {
			var i = h.indexOf(key);
			if (i < 0) return null;
			var j = h.indexOf('http', i);
			if (j < 0 || j - i > 40) return null;
			var e = h.indexOf('"', j);
			if (e < 0) return null;
			var r = h.substring(j, e);
			r = r.replace(/\\+u0026/g, '&').replace(/\\/g, '');
			return r;
		}
		var v = grab('video_url');
		if (!v) { var el = document.querySelector('video'); if (el && el.src) v = el.src; }
		var im = grab('display_url');
		if (!im) { var img = document.querySelector('img.EmbeddedMediaImage'); if (img) im = img.currentSrc || img.src; }
		return JSON.stringify({ video: v, image: im });
	})();
	"""#
	
	/// If the address can't be found, at least hide everything around the video
	static let instagramCleanupScript = #"""
	(function(){
		var s = document.createElement('style');
		s.textContent = '.Header,.HeaderView,.Footer,.SocialProof,.Caption,.CaptionComments,.Feedback,.ActionBar,.EmbedFooter,.HoverCard{display:none!important} html,body{background:#000!important}';
		document.head.appendChild(s);
	})();
	"""#
	
	static func escapeAttribute(_ string: String) -> String {
		return string.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "\"", with: "&quot;").replacingOccurrences(of: "<", with: "&lt;")
	}
	
	/// A page with just the video (or photo), nothing else
	static func mediaHTML(video: String?, image: String?, autoplay: Bool = false) -> String {
		let style = "<style>html,body{margin:0;padding:0;height:100%;background:#000;overflow:hidden}video,img{position:absolute;top:0;left:0;width:100%;height:100%;object-fit:cover}</style>"
		var body = ""
		if let video {
			let poster = image.map { " poster=\"\(escapeAttribute($0))\"" } ?? ""
			body = "<video src=\"\(escapeAttribute(video))\"\(poster) controls controlslist=\"nodownload noremoteplayback\" playsinline loop preload=\"metadata\"\(autoplay ? " autoplay" : "")></video>"
		} else if let image {
			body = "<img src=\"\(escapeAttribute(image))\">"
		}
		return "<!doctype html><html><head><meta name=\"viewport\" content=\"width=device-width,initial-scale=1\">\(style)</head><body>\(body)</body></html>"
	}
	
	static func autoplayURL(_ info: ViralVideo.Info) -> String {
		switch info.provider {
		case "YouTube": return info.embed + "&autoplay=1"
		case "Vimeo": return info.embed + (info.embed.contains("?") ? "&" : "?") + "autoplay=1"
		case "Facebook": return info.embed + "&autoplay=true"
		default: return info.embed
		}
	}
	
	/// `autoplay` starts the video right away (used when a thumbnail is clicked)
	static func load(_ view: WKWebView, url: String, autoplay: Bool = false) {
		// Instagram embeds come with a header, likes and comments. Load the embed page, take the video address from it,
		// and show only the video in a plain player.
		if let info = ViralVideo.info(url), info.provider == "Instagram",
		   let loader = view.navigationDelegate as? ViralVideoLoader, let embed = URL(string: info.embed) {
			loader.autoplay = autoplay
			loader.instagramStage = 1
			view.alphaValue = 0
			view.load(URLRequest(url: embed))
			return
		}
		guard let info = ViralVideo.info(url) else {
			view.loadHTMLString("<html><body style='background:#111;color:#aaa;font:13px -apple-system;display:flex;align-items:center;justify-content:center;height:100vh;margin:0'>This link can't be played here</body></html>", baseURL: baseURL)
			return
		}
		let html = """
		<!doctype html><html><head><meta name="viewport" content="width=device-width,initial-scale=1">
		<style>html,body{margin:0;padding:0;height:100%;background:\(info.provider == "Facebook" ? "#fff" : "#000");overflow:hidden}
		iframe{position:absolute;top:0;left:0;width:100%;height:100%;border:0}</style></head>
		<body><iframe src="\(autoplay ? autoplayURL(info) : info.embed)" allow="autoplay; encrypted-media; picture-in-picture; fullscreen; clipboard-write" allowfullscreen referrerpolicy="strict-origin-when-cross-origin"></iframe></body></html>
		"""
		view.loadHTMLString(html, baseURL: baseURL)
	}
}

/// Takes a snapshot of a video once it has loaded, so the video can be printed
fileprivate final class ViralVideoLoader: NSObject, WKNavigationDelegate, WKUIDelegate {
	var onSnapshot: ((NSImage) -> Void)?
	var wantsSnapshot = false
	
	/// 1 = loading the Instagram embed page, 2 = showing the plain player
	var instagramStage = 0
	var autoplay = false
	
	func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
		if instagramStage == 1 {
			instagramStage = 2
			webView.evaluateJavaScript(ViralWeb.instagramExtractScript) { result, _ in
				var video: String? = nil
				var image: String? = nil
				if let json = result as? String, let data = json.data(using: .utf8),
				   let dict = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
					video = dict["video"] as? String
					image = dict["image"] as? String
				}
				if video != nil || image != nil {
					webView.loadHTMLString(ViralWeb.mediaHTML(video: video, image: image, autoplay: self.autoplay), baseURL: ViralWeb.baseURL)
				} else {
					self.instagramStage = 0
					webView.evaluateJavaScript(ViralWeb.instagramCleanupScript, completionHandler: nil)
					webView.alphaValue = 1
				}
			}
			return
		}
		if instagramStage == 2 {
			instagramStage = 0
			webView.alphaValue = 1
		}
		guard wantsSnapshot else { return }
		DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self, weak webView] in
			guard let self, let webView, self.wantsSnapshot, webView.bounds.width > 20 else { return }
			webView.takeSnapshot(with: nil) { image, _ in
				guard let image, self.wantsSnapshot else { return }
				self.wantsSnapshot = false
				self.onSnapshot?(image)
			}
		}
	}
	
	/// Downloads are blocked, and links that leave the player open in the browser instead
	func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
		if #available(macOS 11.3, *), navigationAction.shouldPerformDownload {
			decisionHandler(.cancel)
			return
		}
		if navigationAction.navigationType == .linkActivated, navigationAction.targetFrame?.isMainFrame ?? true,
		   let url = navigationAction.request.url {
			NSWorkspace.shared.open(url)
			decisionHandler(.cancel)
			return
		}
		decisionHandler(.allow)
	}
	
	func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse, decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
		decisionHandler(navigationResponse.canShowMIMEType ? .allow : .cancel)
	}
	
	/// Links that open new windows go to the browser
	func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
		if let url = navigationAction.request.url { NSWorkspace.shared.open(url) }
		return nil
	}
}

/// A window for signing in to Instagram or Facebook. The session is shared with the videos in documents.
fileprivate final class ViralLoginWindow: NSWindowController, NSWindowDelegate {
	static var current: ViralLoginWindow?
	
	static func show(_ address: String, title: String) {
		guard let url = URL(string: address) else { return }
		let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 520, height: 720), configuration: ViralWeb.configuration())
		web.customUserAgent = ViralWeb.userAgent
		let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 720), styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
		window.title = title
		window.contentView = web
		window.isReleasedWhenClosed = false
		window.center()
		let controller = ViralLoginWindow(window: window)
		window.delegate = controller
		current = controller
		controller.showWindow(nil)
		web.load(URLRequest(url: url))
	}
	
	func windowWillClose(_ notification: Notification) {
		NotificationCenter.default.post(name: ViralVideosReloadNotification, object: nil)
		DispatchQueue.main.async { ViralLoginWindow.current = nil }
	}
}

// MARK: Title page template

@objc final class ViralTitlePageTemplate: NSObject {
	/// The title page `/title` and Screenplay ▸ Add Title Page insert
	@objc static func text() -> String {
		let formatter = DateFormatter()
		formatter.dateFormat = "d MMM yyyy"
		return "Title: \nSave As: \nAuthored by: \nDraft date: \(formatter.string(from: Date()))\nContact: \n\n"
	}
}

// MARK: Image store

fileprivate enum ViralImages {
	static var cache: [String: NSImage] = [:]
	/// Stored image data by ID, shared by all open documents
	static var stored: [String: String] = [:]
	
	static func image(_ id: String, settings: BeatDocumentSettings?) -> NSImage? {
		// NSDictionary lookup: this runs while drawing and laying out, so avoid copying the whole image store
		let dict = settings?.get(ViralImagesKey) as? NSDictionary
		if let encoded = dict?[id] as? String {
			if stored[id] == nil { stored[id] = encoded }
		} else if let settings, let encoded = stored[id] {
			// The text uses an image this document doesn't hold (undo after a save pruned it, or pasted from another document). Put it back.
			let updated = (dict?.mutableCopy() as? NSMutableDictionary) ?? NSMutableDictionary()
			updated[id] = encoded
			settings.set(ViralImagesKey, as: updated)
		}
		
		if let image = cache[id] { return image }
		guard let encoded = stored[id],
			  let data = Data(base64Encoded: encoded, options: .ignoreUnknownCharacters),
			  let image = NSImage(data: data)
		else { return nil }
		cache[id] = image
		return image
	}
	
	static func pixelSize(_ image: NSImage) -> NSSize {
		if let rep = image.representations.first, rep.pixelsWide > 0, rep.pixelsHigh > 0 {
			return NSSize(width: rep.pixelsWide, height: rep.pixelsHigh)
		}
		if image.size.width > 0 && image.size.height > 0 { return image.size }
		return NSSize(width: 4, height: 3)
	}
	
	/// Height divided by width, for an image ID or a video entry
	static func aspect(_ entry: String?, settings: BeatDocumentSettings?) -> CGFloat {
		guard let entry else { return 0.75 }
		if ViralMedia.isVideo(entry) { return ViralVideo.aspect(ViralMedia.url(entry)) }
		guard let image = image(entry, settings: settings) else { return 0.75 }
		let size = pixelSize(image)
		return size.height / max(size.width, 1)
	}
	
	/// Width in percent for a newly added image: its own size, at most the full text width
	static func defaultWidth(_ image: NSImage, textWidth: CGFloat) -> Int {
		let w = image.size.width > 0 ? image.size.width : pixelSize(image).width
		return min(100, max(20, Int((w / max(textWidth, 1) * 100).rounded())))
	}
	
	/// Stores an image in the document and returns its ID. Large images are scaled down.
	static func add(_ image: NSImage, settings: BeatDocumentSettings) -> String? {
		let px = pixelSize(image)
		let scale = min(1, 2000 / max(px.width, px.height))
		let w = max(Int(px.width * scale), 1)
		let h = max(Int(px.height * scale), 1)
		let hasAlpha = image.representations.contains { $0.hasAlpha }
		let usePNG = hasAlpha && w * h <= 1_500_000
		
		guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h, bitsPerSample: 8,
										 samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
										 colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
		else { return nil }
		rep.size = NSSize(width: w, height: h)
		
		NSGraphicsContext.saveGraphicsState()
		NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
		NSGraphicsContext.current?.imageInterpolation = .high
		let rect = NSRect(x: 0, y: 0, width: w, height: h)
		if !usePNG {
			NSColor.white.setFill()
			rect.fill()
		}
		image.draw(in: rect, from: .zero, operation: usePNG ? .copy : .sourceOver, fraction: 1)
		NSGraphicsContext.restoreGraphicsState()
		
		let data = usePNG ? rep.representation(using: .png, properties: [:])
						  : rep.representation(using: .jpeg, properties: [.compressionFactor: 0.85])
		guard let data else { return nil }
		
		let id = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
		var dict = settings.get(ViralImagesKey) as? [String: Any] ?? [:]
		let encoded = data.base64EncodedString()
		dict[id] = encoded
		settings.set(ViralImagesKey, as: dict)
		stored[id] = encoded
		cache[id] = NSImage(data: data) ?? image
		return id
	}
}

/// Images on the pasteboard: image files, or image data (but not rich text that happens to contain images)
fileprivate func viralImages(from pasteboard: NSPasteboard) -> [NSImage] {
	var images: [NSImage] = []
	if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] {
		for url in urls {
			if let image = NSImage(contentsOf: url), !image.representations.isEmpty { images.append(image) }
		}
		if !images.isEmpty { return images }
	}
	
	let imageTypes: [NSPasteboard.PasteboardType] = [.png, .tiff, NSPasteboard.PasteboardType("public.jpeg"), NSPasteboard.PasteboardType("public.heic")]
	let richTypes: [NSPasteboard.PasteboardType] = [.rtf, .rtfd]
	if pasteboard.availableType(from: imageTypes) != nil, pasteboard.availableType(from: richTypes) == nil,
	   let image = NSImage(pasteboard: pasteboard) {
		images.append(image)
	}
	return images
}

/// Video links on the pasteboard (one link per line)
fileprivate func viralVideoLinks(from pasteboard: NSPasteboard) -> [String] {
	var candidates: [String] = []
	if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL] {
		candidates = urls.filter { !$0.isFileURL }.map { $0.absoluteString }
	}
	if candidates.isEmpty, let string = pasteboard.string(forType: .string) {
		candidates = string.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
	}
	guard !candidates.isEmpty, candidates.allSatisfy({ ViralVideo.info($0) != nil }) else { return [] }
	return candidates
}

// MARK: Image group layout

/// Lays out images in rows. An image fits on a row if the widths (plus 2% gaps) stay within 100%.
fileprivate func viralGroupLayout(_ items: [EmbedLine], width: CGFloat, settings: BeatDocumentSettings?, override: [Int: CGFloat] = [:]) -> (frames: [NSRect], height: CGFloat) {
	let gap = floor(width * 0.02)
	var frames = Array(repeating: NSRect.zero, count: items.count)
	
	var rows: [[Int]] = []
	var current: [Int] = []
	var rowPercent = 0
	for (i, item) in items.enumerated() {
		let percent = override[i].map { Int(($0 / max(width, 1) * 100).rounded()) } ?? item.width
		if !current.isEmpty && rowPercent + 2 + percent <= 100 {
			current.append(i)
			rowPercent += 2 + percent
		} else {
			if !current.isEmpty { rows.append(current) }
			current = [i]
			rowPercent = percent
		}
	}
	if !current.isEmpty { rows.append(current) }
	
	var y = EMetrics.marginTop
	for (r, row) in rows.enumerated() {
		var x: CGFloat = 0
		var rowHeight: CGFloat = 0
		for i in row {
			let w = floor(min(width, override[i] ?? width * CGFloat(items[i].width) / 100))
			let h = floor(w * ViralImages.aspect(items[i].ids.first, settings: settings))
			frames[i] = NSRect(x: x, y: y, width: w, height: h)
			x += w + gap
			rowHeight = max(rowHeight, h)
		}
		y += rowHeight
		if r < rows.count - 1 { y += gap }
	}
	return (frames, y + EMetrics.marginBottom)
}

// MARK: Base view

fileprivate class ViralEmbedView: NSView {
	weak var host: BeatTextView?
	var kind: EmbedKind = .image
	var blockRange = NSRange(location: 0, length: 0)
	var sourceText = ""
	var embedWidth: CGFloat = 400
	
	init(host: BeatTextView) {
		self.host = host
		super.init(frame: .zero)
		// Layer backing keeps redraws clean while scrolling and resizing
		wantsLayer = true
		layerContentsRedrawPolicy = .onSetNeedsDisplay
		NotificationCenter.default.addObserver(self, selector: #selector(reloadVideos(_:)), name: ViralVideosReloadNotification, object: nil)
	}
	required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
	deinit { NotificationCenter.default.removeObserver(self) }
	
	override var isFlipped: Bool { return true }
	override var acceptsFirstResponder: Bool { return true }
	
	var isActive: Bool { return window?.firstResponder === self }
	var settings: BeatDocumentSettings? { return host?.editorDelegate?.documentSettings }
	var color: NSColor { return host?.textColor ?? .textColor }
	
	var totalHeight: CGFloat { return 0 }
	func load(text: String, lines: [String]) {}
	func activate(atEnd: Bool) {
		window?.makeFirstResponder(self)
		scrollToVisible(bounds)
	}
	func addImages(_ images: [NSImage]) {}
	func addVideos(_ urls: [String]) {}
	@objc func reloadVideos(_ notification: Notification?) {}
	/// Close video players and show thumbnails instead (called when far off screen)
	func suspendPlayers() {}
	
	// The window only switches its first responder after these return, so redraw on the next turn
	override func becomeFirstResponder() -> Bool { DispatchQueue.main.async { [weak self] in self?.redraw() }; return true }
	override func resignFirstResponder() -> Bool { DispatchQueue.main.async { [weak self] in self?.redraw() }; return true }
	
	func redraw() {
		needsDisplay = true
		for view in subviews { view.needsDisplay = true }
		updateChrome()
	}
	func updateChrome() {}
	
	/// Writes this block's lines back into the document
	func write(_ lines: [String]) {
		guard let host else { return }
		let text = lines.joined(separator: "\n")
		let wasActive = isActive
		sourceText = text
		host.replaceBlockText(blockRange, with: text)
		blockRange.length = (text as NSString).length
		if wasActive && window?.firstResponder !== self { window?.makeFirstResponder(self) }
		host.scheduleTableUpdate()
	}
	
	func newImageLines(_ images: [NSImage]) -> [EmbedLine] {
		guard let settings else { return [] }
		return images.compactMap { image in
			guard let id = ViralImages.add(image, settings: settings) else { return nil }
			return EmbedLine(kind: .image, ids: [id], width: ViralImages.defaultWidth(image, textWidth: embedWidth))
		}
	}
	
	@objc func paste(_ sender: Any?) {
		let pasteboard = NSPasteboard.general
		let links = viralVideoLinks(from: pasteboard)
		if !links.isEmpty { addVideos(links); return }
		let images = viralImages(from: pasteboard)
		if images.isEmpty { NSSound.beep(); return }
		addImages(images)
	}
	
	@objc func chooseAndAddImages(_ sender: Any?) {
		host?.chooseImages { [weak self] images in self?.addImages(images) }
	}
	
	@objc func signInToInstagram(_ sender: Any?) { ViralLoginWindow.show("https://www.instagram.com/accounts/login/", title: "Sign In to Instagram") }
	@objc func signInToFacebook(_ sender: Any?) { ViralLoginWindow.show("https://www.facebook.com/login/", title: "Sign In to Facebook") }
	
	func signInMenu(into menu: NSMenu) {
		let instagram = NSMenuItem(title: "Sign In to Instagram…", action: #selector(signInToInstagram(_:)), keyEquivalent: "")
		instagram.target = self
		menu.addItem(instagram)
		let facebook = NSMenuItem(title: "Sign In to Facebook…", action: #selector(signInToFacebook(_:)), keyEquivalent: "")
		facebook.target = self
		menu.addItem(facebook)
	}
	
	override func keyDown(with event: NSEvent) {
		switch event.keyCode {
		case 53, 36, 76: host?.exitEmbed(self, below: true)
		case 126: host?.exitEmbed(self, below: false)
		case 125: host?.exitEmbed(self, below: true)
		default:
			// Never let typing fall through to the hidden text behind the block
			if event.modifierFlags.contains(.command) { super.keyDown(with: event) } else { NSSound.beep() }
		}
	}
	
	func widthMenu(into menu: NSMenu) {
		let sizes = NSMenuItem(title: "Size", action: nil, keyEquivalent: "")
		let sub = NSMenu()
		for percent in [25, 33, 50, 75, 100] {
			let item = NSMenuItem(title: "\(percent)%", action: #selector(setWidthFromMenu(_:)), keyEquivalent: "")
			item.tag = percent
			item.target = self
			sub.addItem(item)
		}
		sizes.submenu = sub
		menu.addItem(sizes)
	}
	
	@objc func setWidthFromMenu(_ sender: NSMenuItem) {}
}

/// The little square in the corner for resizing
fileprivate final class ViralHandleView: NSView {
	var onBegin: ((NSEvent) -> Void)?
	var onDrag: ((NSEvent) -> Void)?
	var onEnd: ((NSEvent) -> Void)?
	var cursor: NSCursor = .resizeLeftRight
	
	override func draw(_ dirtyRect: NSRect) {
		let rect = bounds.insetBy(dx: 1, dy: 1)
		NSColor.controlAccentColor.setFill()
		NSBezierPath(roundedRect: rect, xRadius: 2, yRadius: 2).fill()
		NSColor.white.setStroke()
		let line = NSBezierPath()
		line.move(to: NSPoint(x: rect.minX + 3, y: rect.minY + 3))
		line.line(to: NSPoint(x: rect.maxX - 3, y: rect.maxY - 3))
		line.lineWidth = 1
		line.stroke()
	}
	override func resetCursorRects() { addCursorRect(bounds, cursor: cursor) }
	override func mouseDown(with event: NSEvent) { onBegin?(event) }
	override func mouseDragged(with event: NSEvent) { onDrag?(event) }
	override func mouseUp(with event: NSEvent) { onEnd?(event) }
}

// MARK: Image tile

fileprivate final class ViralImageTile: NSView {
	weak var group: ViralImageGroupView?
	var index = 0
	var image: NSImage?
	var videoURL: String?
	var webView: WKWebView?
	/// The link the web view was loaded with
	var webViewURL: String?
	/// Set when the player was opened (click), so it stays until it scrolls far away
	var playerActive = false
	let loader = ViralVideoLoader()
	let handle = ViralHandleView(frame: .zero)
	let menuButton = NSButton(frame: .zero)
	var hovering = false
	var resizing = false
	var startX: CGFloat = 0
	var startWidth: CGFloat = 0
	
	override var isFlipped: Bool { return true }
	
	override init(frame frameRect: NSRect) {
		super.init(frame: frameRect)
		wantsLayer = true
		layerContentsRedrawPolicy = .onSetNeedsDisplay
		
		handle.onBegin = { [weak self] event in self?.beginResize(event) }
		handle.onDrag = { [weak self] event in self?.dragResize(event) }
		handle.onEnd = { [weak self] event in self?.endResize(event) }
		addSubview(handle)
		
		menuButton.isBordered = false
		menuButton.bezelStyle = .regularSquare
		menuButton.title = ""
		if let image = NSImage(systemSymbolName: "ellipsis.circle.fill", accessibilityDescription: "Options") {
			menuButton.image = image.withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 18, weight: .regular)) ?? image
			menuButton.imagePosition = .imageOnly
		} else {
			menuButton.title = "•••"
		}
		menuButton.contentTintColor = .white
		menuButton.target = self
		menuButton.action = #selector(showMenu(_:))
		menuButton.toolTip = "Options"
		addSubview(menuButton)
		updateChrome()
	}
	required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
	
	var item: EmbedLine? {
		guard let group, index < group.items.count else { return nil }
		return group.items[index]
	}
	var isSelected: Bool { return group?.isActive == true && group?.selectedIndex == index }
	
	func configure(entry: String?, settings: BeatDocumentSettings?) {
		guard let entry else { image = nil; return }
		if ViralMedia.isVideo(entry) {
			let url = ViralMedia.url(entry)
			let thumbnail = ViralMedia.thumbnail(entry)
			if videoURL != url { playerActive = false }
			videoURL = url
			// Videos show their thumbnail until clicked. A web player per video makes scrolling slow.
			// Without a thumbnail yet, the player loads once to take one.
			let keepPlayer = webView != nil && webViewURL == url
			if playerActive || thumbnail == nil || keepPlayer {
				if !keepPlayer {
					webView?.removeFromSuperview()
					let web = ViralWeb.makeView()
					web.navigationDelegate = loader
					web.uiDelegate = loader
					addSubview(web, positioned: .below, relativeTo: handle)
					webView = web
					webViewURL = url
					ViralWeb.load(web, url: url, autoplay: playerActive)
				}
			}
			image = thumbnail.flatMap { ViralImages.image($0, settings: settings) }
			loader.wantsSnapshot = (thumbnail == nil)
			let tileIndex = index
			loader.onSnapshot = { [weak self] snapshot in
				guard let self, let group = self.group else { return }
				group.setThumbnail(snapshot, at: tileIndex)
			}
		} else {
			videoURL = nil
			webView?.removeFromSuperview()
			webView = nil
			webViewURL = nil
			playerActive = false
			loader.wantsSnapshot = false
			image = ViralImages.image(entry, settings: settings)
		}
		layoutChrome()
		updateChrome()
		needsDisplay = true
	}
	
	func reloadVideo() {
		guard let webView, let videoURL else { return }
		ViralWeb.load(webView, url: videoURL)
	}
	
	/// Opens the player for a video that shows its thumbnail
	func openPlayer() {
		guard videoURL != nil, webView == nil, let entry = item?.ids.first else { return }
		playerActive = true
		configure(entry: entry, settings: group?.settings)
	}
	
	/// Closes the player and shows the thumbnail again (only when there is one)
	func closePlayer() {
		guard let webView, let entry = item?.ids.first, ViralMedia.thumbnail(entry) != nil else { return }
		webView.removeFromSuperview()
		self.webView = nil
		webViewURL = nil
		playerActive = false
		updateChrome()
		needsDisplay = true
	}
	
	override func setFrameSize(_ newSize: NSSize) {
		super.setFrameSize(newSize)
		layoutChrome()
	}
	
	func layoutChrome() {
		webView?.frame = bounds
		if let webView { ViralWeb.fitZoom(webView, url: videoURL) }
		handle.frame = NSRect(x: bounds.maxX - EMetrics.handle - 2, y: bounds.maxY - EMetrics.handle - 2, width: EMetrics.handle, height: EMetrics.handle)
		menuButton.frame = NSRect(x: bounds.maxX - 30, y: 6, width: 24, height: 24)
		let radius = (item?.rounded ?? false) ? EmbedLine.cornerRadius(bounds) : 0
		layer?.cornerRadius = radius
		layer?.masksToBounds = radius > 0
	}
	
	func updateChrome() {
		let selected = isSelected || resizing
		handle.isHidden = !(selected || hovering)
		menuButton.isHidden = !(videoURL != nil && (selected || hovering))
		layer?.borderWidth = selected ? 2 : (hovering ? 1 : 0)
		layer?.borderColor = (selected ? NSColor.controlAccentColor : (group?.color ?? .textColor).withAlphaComponent(0.3)).cgColor
		layoutChrome()
	}
	
	override func draw(_ dirtyRect: NSRect) {
		guard webView == nil else { return }
		if let image {
			image.draw(in: bounds, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true,
					   hints: [.interpolation: NSNumber(value: NSImageInterpolation.high.rawValue)])
			if videoURL != nil { ViralImageTile.drawPlayButton(in: bounds) }
		} else if videoURL != nil {
			NSColor.black.setFill()
			bounds.fill()
			ViralImageTile.drawPlayButton(in: bounds)
		} else {
			(group?.color ?? .textColor).withAlphaComponent(0.08).setFill()
			bounds.fill()
			let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor]
			let text = NSAttributedString(string: "Missing image", attributes: attrs)
			text.draw(at: NSPoint(x: bounds.midX - text.size().width / 2, y: bounds.midY - text.size().height / 2))
		}
	}
	
	override func updateTrackingAreas() {
		super.updateTrackingAreas()
		for area in trackingAreas { removeTrackingArea(area) }
		addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self, userInfo: nil))
	}
	override func mouseEntered(with event: NSEvent) { hovering = true; updateChrome() }
	override func mouseExited(with event: NSEvent) { hovering = false; updateChrome() }
	
	override func mouseDown(with event: NSEvent) {
		group?.select(index)
		openPlayer()
	}
	
	/// A round play button in the middle of a video thumbnail
	static func drawPlayButton(in rect: NSRect) {
		let size = min(56, max(28, min(rect.width, rect.height) * 0.22))
		let circle = NSRect(x: rect.midX - size / 2, y: rect.midY - size / 2, width: size, height: size)
		NSColor.black.withAlphaComponent(0.45).setFill()
		NSBezierPath(ovalIn: circle).fill()
		let t = size * 0.32
		let path = NSBezierPath()
		path.move(to: NSPoint(x: circle.midX - t * 0.4, y: circle.midY - t * 0.6))
		path.line(to: NSPoint(x: circle.midX + t * 0.6, y: circle.midY))
		path.line(to: NSPoint(x: circle.midX - t * 0.4, y: circle.midY + t * 0.6))
		path.close()
		NSColor.white.setFill()
		path.fill()
	}
	
	func beginResize(_ event: NSEvent) {
		guard let group else { return }
		group.select(index)
		resizing = true
		startX = group.convert(event.locationInWindow, from: nil).x
		startWidth = frame.width
		updateChrome()
	}
	
	func dragResize(_ event: NSEvent) {
		guard resizing, let group else { return }
		let x = group.convert(event.locationInWindow, from: nil).x
		let width = max(40, min(group.embedWidth, startWidth + x - startX))
		group.preview(index: index, width: width)
	}
	
	func endResize(_ event: NSEvent) {
		guard resizing, let group else { return }
		resizing = false
		group.commit(index: index, width: frame.width)
		updateChrome()
	}
	
	@objc func showMenu(_ sender: Any?) {
		guard let group else { return }
		group.select(index)
		let menu = group.contextMenu()
		_ = menu.popUp(positioning: nil, at: NSPoint(x: menuButton.frame.minX, y: menuButton.frame.maxY), in: self)
	}
	
	override func menu(for event: NSEvent) -> NSMenu? {
		group?.select(index)
		return group?.contextMenu()
	}
}

// MARK: Image group

fileprivate final class ViralImageGroupView: ViralEmbedView {
	var items: [EmbedLine] = []
	var tiles: [ViralImageTile] = []
	var selectedIndex = 0
	var previewWidths: [Int: CGFloat] = [:]
	
	override init(host: BeatTextView) {
		super.init(host: host)
		kind = .image
	}
	required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
	
	override var totalHeight: CGFloat {
		return viralGroupLayout(items, width: embedWidth, settings: settings).height
	}
	
	override func load(text: String, lines: [String]) {
		sourceText = text
		items = lines.compactMap { EmbedLine.parse($0) }
		reloadTiles()
	}
	
	func reloadTiles() {
		while tiles.count < items.count {
			let tile = ViralImageTile(frame: .zero)
			tile.group = self
			addSubview(tile)
			tiles.append(tile)
		}
		while tiles.count > items.count { tiles.removeLast().removeFromSuperview() }
		for (i, tile) in tiles.enumerated() {
			tile.index = i
			tile.configure(entry: items[i].ids.first, settings: settings)
		}
		selectedIndex = min(selectedIndex, max(items.count - 1, 0))
		relayout()
	}
	
	func relayout() {
		let frames = viralGroupLayout(items, width: embedWidth, settings: settings, override: previewWidths).frames
		for (i, tile) in tiles.enumerated() where i < frames.count {
			if tile.frame != frames[i] { tile.frame = frames[i] }
			tile.updateChrome()
			tile.needsDisplay = true
		}
		window?.invalidateCursorRects(for: self)
	}
	
	override func updateChrome() {
		for tile in tiles { tile.updateChrome() }
	}
	
	override func reloadVideos(_ notification: Notification?) {
		for tile in tiles { tile.reloadVideo() }
	}
	
	override func suspendPlayers() {
		for tile in tiles { tile.closePlayer() }
	}
	
	override func activate(atEnd: Bool) {
		selectedIndex = atEnd ? max(items.count - 1, 0) : 0
		super.activate(atEnd: atEnd)
		if selectedIndex < tiles.count { tiles[selectedIndex].scrollToVisible(tiles[selectedIndex].bounds) }
	}
	
	func select(_ index: Int) {
		selectedIndex = index
		if !isActive { window?.makeFirstResponder(self) }
		redraw()
	}
	
	func preview(index: Int, width: CGFloat) {
		previewWidths = [index: width]
		relayout()
		// Grow the view while dragging so the image isn't clipped
		let height = viralGroupLayout(items, width: embedWidth, settings: settings, override: previewWidths).height
		if height > frame.height { setFrameSize(NSSize(width: frame.width, height: height)) }
	}
	
	func commit(index: Int, width: CGFloat) {
		previewWidths = [:]
		guard index < items.count else { return }
		items[index].width = min(max(Int((width / max(embedWidth, 1) * 100).rounded()), 5), 100)
		relayout()
		write(items.map { $0.text })
	}
	
	func setThumbnail(_ image: NSImage, at index: Int) {
		guard index < items.count, let settings, let entry = items[index].ids.first,
			  ViralMedia.isVideo(entry), ViralMedia.thumbnail(entry) == nil,
			  let id = ViralImages.add(image, settings: settings)
		else { return }
		items[index].ids[0] = ViralMedia.make(url: ViralMedia.url(entry), thumbnail: id)
		write(items.map { $0.text })
	}
	
	override func setWidthFromMenu(_ sender: NSMenuItem) {
		guard selectedIndex < items.count else { return }
		items[selectedIndex].width = sender.tag
		relayout()
		write(items.map { $0.text })
	}
	
	func insertItems(_ lines: [EmbedLine]) {
		guard !lines.isEmpty else { return }
		let at = min(selectedIndex + 1, items.count)
		items.insert(contentsOf: lines, at: at)
		selectedIndex = at + lines.count - 1
		reloadTiles()
		write(items.map { $0.text })
	}
	
	override func addImages(_ images: [NSImage]) {
		insertItems(newImageLines(images))
	}
	
	override func addVideos(_ urls: [String]) {
		insertItems(urls.map { EmbedLine(kind: .video, ids: [ViralMedia.make(url: $0, thumbnail: nil)], width: 33) })
	}
	
	func deleteSelected() {
		guard selectedIndex < items.count else { return }
		items.remove(at: selectedIndex)
		if items.isEmpty {
			host?.deleteEmbed(self)
			return
		}
		selectedIndex = min(selectedIndex, items.count - 1)
		reloadTiles()
		write(items.map { $0.text })
	}
	
	@objc func delete(_ sender: Any?) { deleteSelected() }
	@objc func deleteImageFromMenu(_ sender: Any?) { deleteSelected() }
	@objc func toggleRounded(_ sender: Any?) {
		guard selectedIndex < items.count else { return }
		items[selectedIndex].rounded.toggle()
		relayout()
		write(items.map { $0.text })
	}
	@objc func openInBrowser(_ sender: Any?) {
		guard selectedIndex < items.count, let entry = items[selectedIndex].ids.first, ViralMedia.isVideo(entry),
			  let url = URL(string: ViralMedia.url(entry)) else { return }
		NSWorkspace.shared.open(url)
	}
	
	override func keyDown(with event: NSEvent) {
		switch event.keyCode {
		case 51, 117: deleteSelected()
		case 123:
			if selectedIndex > 0 { select(selectedIndex - 1) } else { host?.exitEmbed(self, below: false) }
		case 124:
			if selectedIndex < items.count - 1 { select(selectedIndex + 1) } else { host?.exitEmbed(self, below: true) }
		default: super.keyDown(with: event)
		}
	}
	
	func contextMenu() -> NSMenu {
		let menu = NSMenu()
		let isVideo = selectedIndex < items.count && items[selectedIndex].kind == .video
		widthMenu(into: menu)
		let round = NSMenuItem(title: "Rounded Corners", action: #selector(toggleRounded(_:)), keyEquivalent: "")
		round.target = self
		round.state = (selectedIndex < items.count && items[selectedIndex].rounded) ? .on : .off
		menu.addItem(round)
		menu.addItem(NSMenuItem.separator())
		if isVideo {
			let open = NSMenuItem(title: "Open in Browser", action: #selector(openInBrowser(_:)), keyEquivalent: "")
			open.target = self
			menu.addItem(open)
			signInMenu(into: menu)
			menu.addItem(NSMenuItem.separator())
		}
		let add = NSMenuItem(title: "Add Images…", action: #selector(chooseAndAddImages(_:)), keyEquivalent: "")
		add.target = self
		menu.addItem(add)
		let delete = NSMenuItem(title: isVideo ? "Delete Video" : "Delete Image", action: #selector(deleteImageFromMenu(_:)), keyEquivalent: "")
		delete.target = self
		menu.addItem(delete)
		return menu
	}
	
	override func menu(for event: NSEvent) -> NSMenu? { return contextMenu() }
}

// MARK: Carousel

/// Draws the soft fade at both edges of a carousel, plus the selection and resize handle
fileprivate final class ViralCarouselOverlay: NSView {
	weak var carousel: ViralCarouselView?
	override var isFlipped: Bool { return true }
	override func hitTest(_ point: NSPoint) -> NSView? { return nil }
	
	override func draw(_ dirtyRect: NSRect) {
		guard let carousel else { return }
		let strip = carousel.stripRect
		let fade = ThemeManager.shared().backgroundColor.effectiveColor()
		
		if carousel.scrollX > 0.5 || carousel.maxScroll > 0.5 {
			// A solid edge first, so nothing (like a video's black background) peeks out at the page edge
			fade.setFill()
			NSRect(x: strip.minX, y: strip.minY, width: 3, height: strip.height).fill()
			NSRect(x: strip.maxX - 3, y: strip.minY, width: 3, height: strip.height).fill()
			let left = NSGradient(colors: [fade, fade.withAlphaComponent(0.85), fade.withAlphaComponent(0)], atLocations: [0, 0.35, 1], colorSpace: .sRGB)
			left?.draw(in: NSRect(x: strip.minX + 3, y: strip.minY, width: EMetrics.fade, height: strip.height), angle: 0)
			let right = NSGradient(colors: [fade.withAlphaComponent(0), fade.withAlphaComponent(0.85), fade], atLocations: [0, 0.65, 1], colorSpace: .sRGB)
			right?.draw(in: NSRect(x: strip.maxX - 3 - EMetrics.fade, y: strip.minY, width: EMetrics.fade, height: strip.height), angle: 0)
		}
		
		if carousel.isActive, let frame = carousel.visibleFrame(of: carousel.selectedIndex) {
			NSColor.controlAccentColor.setStroke()
			let radius = carousel.item.rounded ? EmbedLine.cornerRadius(frame) : 0
			let outline = NSBezierPath(roundedRect: frame.insetBy(dx: 1, dy: 1), xRadius: radius, yRadius: radius)
			outline.lineWidth = 2
			outline.stroke()
		}
	}
}

/// A horizontal strip of images and videos at the carousel height, running edge to edge on the page
fileprivate final class ViralCarouselView: ViralEmbedView {
	var item = EmbedLine(kind: .carousel, ids: [], width: 100)
	var selectedIndex = 0
	var scrollX: CGFloat = 0
	/// Space before the first image, so it lines up with the text
	var textInset: CGFloat = 50
	var hovering = false
	var resizing = false
	var resizeStartY: CGFloat = 0
	var resizeStartHeight: CGFloat = 0
	var previewHeight: CGFloat? = nil
	var animation: Timer? = nil
	
	var videos: [Int: (url: String, view: WKWebView, loader: ViralVideoLoader)] = [:]
	/// Videos opened with a click. The others show their thumbnail (a web player per video makes scrolling slow).
	var openVideos = Set<String>()
	let clip = ViralFlippedView(frame: .zero)
	let overlay = ViralCarouselOverlay(frame: .zero)
	let handle = ViralHandleView(frame: .zero)
	let previousButton = NSButton(frame: .zero)
	let nextButton = NSButton(frame: .zero)
	let addButton = NSButton(frame: .zero)
	
	static let gap: CGFloat = 10
	
	/// Text width is the reference for the height percentage
	static func stripHeight(for item: EmbedLine, textWidth: CGFloat) -> CGFloat {
		return max(60, floor(textWidth * CGFloat(item.height) / 100))
	}
	
	static func height(for item: EmbedLine, textWidth: CGFloat) -> CGFloat {
		return EMetrics.marginTop + stripHeight(for: item, textWidth: textWidth) + EMetrics.marginBottom
	}
	
	var textWidth: CGFloat { return max(embedWidth - textInset * 2, 100) }
	
	override init(host: BeatTextView) {
		super.init(host: host)
		kind = .carousel
		clip.wantsLayer = true
		clip.layer?.masksToBounds = true
		addSubview(clip)
		overlay.carousel = self
		addSubview(overlay)
		
		handle.cursor = .resizeUpDown
		handle.onBegin = { [weak self] event in self?.beginResize(event) }
		handle.onDrag = { [weak self] event in self?.dragResize(event) }
		handle.onEnd = { [weak self] event in self?.endResize(event) }
		addSubview(handle)
		
		setup(previousButton, symbol: "chevron.left.circle.fill", fallback: "‹", tip: "Scroll left", action: #selector(showPrevious(_:)))
		setup(nextButton, symbol: "chevron.right.circle.fill", fallback: "›", tip: "Scroll right", action: #selector(showNext(_:)))
		setup(addButton, symbol: "plus.circle.fill", fallback: "+", tip: "Add images", action: #selector(chooseAndAddImages(_:)))
	}
	required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
	
	func setup(_ button: NSButton, symbol: String, fallback: String, tip: String, action: Selector) {
		button.isBordered = false
		button.bezelStyle = .regularSquare
		button.title = ""
		button.toolTip = tip
		if let image = NSImage(systemSymbolName: symbol, accessibilityDescription: tip) {
			button.image = image.withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 24, weight: .regular)) ?? image
			button.imagePosition = .imageOnly
			button.imageScaling = .scaleProportionallyUpOrDown
		} else {
			button.title = fallback
		}
		button.contentTintColor = NSColor(white: 0.1, alpha: 0.7)
		button.wantsLayer = true
		button.layer?.shadowColor = NSColor.white.cgColor
		button.layer?.shadowOpacity = 0.9
		button.layer?.shadowRadius = 3
		button.layer?.shadowOffset = .zero
		button.target = self
		button.action = action
		addSubview(button)
	}
	
	var stripHeight: CGFloat { return previewHeight ?? ViralCarouselView.stripHeight(for: item, textWidth: textWidth) }
	var stripRect: NSRect { return NSRect(x: 0, y: EMetrics.marginTop, width: embedWidth, height: stripHeight) }
	
	override var totalHeight: CGFloat { return ViralCarouselView.height(for: item, textWidth: textWidth) }
	
	/// Item frames in strip coordinates (before scrolling)
	var itemFrames: [NSRect] {
		let h = stripHeight
		var x = textInset
		var frames: [NSRect] = []
		for entry in item.ids {
			let aspect = ViralImages.aspect(entry, settings: settings)
			let w = max(20, floor(h / max(aspect, 0.05)))
			frames.append(NSRect(x: x, y: EMetrics.marginTop, width: w, height: h))
			x += w + ViralCarouselView.gap
		}
		return frames
	}
	
	var contentWidth: CGFloat {
		guard let last = itemFrames.last else { return 0 }
		return last.maxX + textInset
	}
	
	var maxScroll: CGFloat { return max(0, contentWidth - embedWidth) }
	
	func visibleFrame(of index: Int) -> NSRect? {
		let frames = itemFrames
		guard index < frames.count else { return nil }
		return frames[index].offsetBy(dx: -scrollX, dy: 0)
	}
	
	override func load(text: String, lines: [String]) {
		sourceText = text
		item = EmbedLine.parse(lines.first ?? "") ?? EmbedLine(kind: .carousel, ids: [], width: 100)
		selectedIndex = min(selectedIndex, max(item.ids.count - 1, 0))
		relayout()
	}
	
	override func reloadVideos(_ notification: Notification?) {
		for (_, video) in videos { ViralWeb.load(video.view, url: video.url) }
	}
	
	/// Creates, moves and removes the video views
	func layoutVideos() {
		let frames = itemFrames
		var keep = Set<Int>()
		for (i, entry) in item.ids.enumerated() where ViralMedia.isVideo(entry) && i < frames.count {
			let url = ViralMedia.url(entry)
			let hasThumbnail = ViralMedia.thumbnail(entry) != nil
			// Thumbnail only, until the video is clicked (a player still loads once to take the thumbnail)
			guard openVideos.contains(url) || !hasThumbnail || videos[i]?.url == url else { continue }
			if videos[i]?.url != url {
				videos[i]?.view.removeFromSuperview()
				let web = ViralWeb.makeView()
				let loader = ViralVideoLoader()
				web.navigationDelegate = loader
				web.uiDelegate = loader
				clip.addSubview(web)
				ViralWeb.load(web, url: url, autoplay: openVideos.contains(url))
				videos[i] = (url, web, loader)
			}
			if let video = videos[i] {
				video.loader.wantsSnapshot = (ViralMedia.thumbnail(entry) == nil)
				video.loader.onSnapshot = { [weak self] image in self?.setThumbnail(image, at: i) }
				let frame = frames[i].offsetBy(dx: -scrollX, dy: -EMetrics.marginTop)
				video.view.frame = frame
				ViralWeb.fitZoom(video.view, url: url)
				let radius = item.rounded ? EmbedLine.cornerRadius(frame) : 0
				video.view.layer?.cornerRadius = radius
				video.view.layer?.masksToBounds = radius > 0
			}
			keep.insert(i)
		}
		for key in videos.keys where !keep.contains(key) {
			videos[key]?.view.removeFromSuperview()
			videos[key] = nil
		}
	}
	
	func relayout() {
		scrollX = min(max(scrollX, 0), maxScroll)
		let strip = stripRect
		clip.frame = strip
		overlay.frame = bounds
		layoutVideos()
		
		let size: CGFloat = 30
		previousButton.frame = NSRect(x: strip.minX + 10, y: strip.midY - size / 2, width: size, height: size)
		nextButton.frame = NSRect(x: strip.maxX - 10 - size, y: strip.midY - size / 2, width: size, height: size)
		addButton.frame = NSRect(x: textInset + 8, y: strip.minY + 8, width: 24, height: 24)
		handle.frame = NSRect(x: strip.maxX - textInset - EMetrics.handle, y: strip.maxY - EMetrics.handle, width: EMetrics.handle, height: EMetrics.handle)
		previousButton.isHidden = scrollX <= 0.5
		nextButton.isHidden = scrollX >= maxScroll - 0.5
		updateChrome()
		window?.invalidateCursorRects(for: self)
		needsDisplay = true
		overlay.needsDisplay = true
	}
	
	override func updateChrome() {
		handle.isHidden = !(isActive || hovering || resizing)
		addButton.isHidden = !(isActive || hovering || item.ids.isEmpty)
		overlay.needsDisplay = true
	}
	
	override func draw(_ dirtyRect: NSRect) {
		let strip = stripRect
		
		if item.ids.isEmpty {
			let box = NSRect(x: textInset, y: strip.minY, width: textWidth, height: strip.height)
			let path = NSBezierPath(roundedRect: box, xRadius: 6, yRadius: 6)
			color.withAlphaComponent(0.05).setFill()
			path.fill()
			let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.secondaryLabelColor]
			let text = NSAttributedString(string: "Paste or drop images and video links here, or click +", attributes: attrs)
			let s = text.size()
			text.draw(at: NSPoint(x: box.midX - s.width / 2, y: box.midY - s.height / 2))
			return
		}
		
		NSGraphicsContext.saveGraphicsState()
		NSBezierPath(rect: strip).addClip()
		for (i, frame) in itemFrames.enumerated() {
			let entry = item.ids[i]
			let isVideo = ViralMedia.isVideo(entry)
			if isVideo && videos[i] != nil { continue }
			let rect = frame.offsetBy(dx: -scrollX, dy: 0)
			guard rect.maxX > strip.minX, rect.minX < strip.maxX else { continue }
			let radius = item.rounded ? EmbedLine.cornerRadius(rect) : 0
			NSGraphicsContext.saveGraphicsState()
			NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).addClip()
			let imageID = isVideo ? ViralMedia.thumbnail(entry) : entry
			if let imageID, let image = ViralImages.image(imageID, settings: settings) {
				image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true,
						   hints: [.interpolation: NSNumber(value: NSImageInterpolation.high.rawValue)])
				if isVideo { ViralImageTile.drawPlayButton(in: rect) }
			} else if isVideo {
				NSColor.black.setFill()
				rect.fill()
				ViralImageTile.drawPlayButton(in: rect)
			} else {
				color.withAlphaComponent(0.1).setFill()
				rect.fill()
			}
			NSGraphicsContext.restoreGraphicsState()
		}
		NSGraphicsContext.restoreGraphicsState()
	}
	
	override func updateTrackingAreas() {
		super.updateTrackingAreas()
		for area in trackingAreas { removeTrackingArea(area) }
		addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self, userInfo: nil))
	}
	override func mouseEntered(with event: NSEvent) { hovering = true; updateChrome() }
	override func mouseExited(with event: NSEvent) { hovering = false; updateChrome() }
	
	override func mouseDown(with event: NSEvent) {
		window?.makeFirstResponder(self)
		let point = convert(event.locationInWindow, from: nil)
		if let i = itemFrames.firstIndex(where: { $0.offsetBy(dx: -scrollX, dy: 0).contains(point) }) {
			selectedIndex = i
			let entry = item.ids[i]
			if ViralMedia.isVideo(entry) && videos[i] == nil {
				openVideos.insert(ViralMedia.url(entry))
				layoutVideos()
				needsDisplay = true
			}
			scrollToSelected()
		}
		updateChrome()
	}
	
	override func suspendPlayers() {
		guard !videos.isEmpty else { return }
		openVideos.removeAll()
		for (i, video) in videos {
			let entry = i < item.ids.count ? item.ids[i] : ""
			guard ViralMedia.thumbnail(entry) != nil else { continue }
			video.view.removeFromSuperview()
			videos[i] = nil
		}
		needsDisplay = true
	}
	
	func beginResize(_ event: NSEvent) {
		window?.makeFirstResponder(self)
		resizing = true
		resizeStartY = convert(event.locationInWindow, from: nil).y
		resizeStartHeight = stripHeight
		updateChrome()
	}
	
	func dragResize(_ event: NSEvent) {
		guard resizing else { return }
		let y = convert(event.locationInWindow, from: nil).y
		previewHeight = max(60, min(textWidth * 1.5, resizeStartHeight + y - resizeStartY))
		let height = EMetrics.marginTop + stripHeight + EMetrics.marginBottom
		if height > frame.height { setFrameSize(NSSize(width: frame.width, height: height)) }
		relayout()
	}
	
	func endResize(_ event: NSEvent) {
		guard resizing else { return }
		resizing = false
		let height = stripHeight
		previewHeight = nil
		item.height = min(max(Int((height / max(textWidth, 1) * 100).rounded()), 10), 150)
		relayout()
		write([item.text])
	}
	
	/// Sideways trackpad scrolling moves the strip, vertical scrolling scrolls the document
	override func scrollWheel(with event: NSEvent) {
		if abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) && maxScroll > 0 {
			animation?.invalidate()
			let factor: CGFloat = event.hasPreciseScrollingDeltas ? 1 : 10
			scrollX = min(max(scrollX - event.scrollingDeltaX * factor, 0), maxScroll)
			relayout()
		} else {
			super.scrollWheel(with: event)
		}
	}
	
	func animateScroll(to target: CGFloat) {
		animation?.invalidate()
		let start = scrollX
		let end = min(max(target, 0), maxScroll)
		guard abs(end - start) > 0.5 else { return }
		let began = Date()
		let duration = 0.3
		animation = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self] timer in
			guard let self else { timer.invalidate(); return }
			let t = min(1, Date().timeIntervalSince(began) / duration)
			let eased = 1 - pow(1 - t, 3)
			self.scrollX = start + (end - start) * CGFloat(eased)
			self.relayout()
			if t >= 1 { timer.invalidate() }
		}
	}
	
	/// Scrolls so that the selected item is fully visible inside the text area
	func scrollToSelected() {
		let frames = itemFrames
		guard selectedIndex < frames.count else { return }
		let frame = frames[selectedIndex]
		if frame.minX - textInset < scrollX {
			animateScroll(to: frame.minX - textInset)
		} else if frame.maxX + textInset > scrollX + embedWidth {
			animateScroll(to: frame.maxX + textInset - embedWidth)
		}
	}
	
	@objc func showPrevious(_ sender: Any?) {
		let frames = itemFrames
		if let i = frames.lastIndex(where: { $0.minX - textInset < scrollX - 1 }) {
			var target = max(frames[i].maxX + textInset - embedWidth, scrollX - textWidth * 0.8)
			if target >= scrollX - 1 { target = scrollX - textWidth * 0.8 }
			animateScroll(to: target)
			selectedIndex = i
		} else {
			animateScroll(to: 0)
		}
		updateChrome()
	}
	
	@objc func showNext(_ sender: Any?) {
		let frames = itemFrames
		let right = scrollX + embedWidth - textInset
		if let i = frames.firstIndex(where: { $0.maxX > right + 1 }) {
			var target = min(frames[i].minX - textInset, scrollX + textWidth * 0.8)
			if target <= scrollX + 1 { target = scrollX + textWidth * 0.8 }
			animateScroll(to: target)
			selectedIndex = i
		} else {
			animateScroll(to: maxScroll)
		}
		updateChrome()
	}
	
	func insertEntries(_ entries: [String]) {
		guard !entries.isEmpty else { return }
		let at = item.ids.isEmpty ? 0 : min(selectedIndex + 1, item.ids.count)
		// Video views are keyed by position, so they are rebuilt after an insert
		for (_, video) in videos { video.view.removeFromSuperview() }
		videos = [:]
		item.ids.insert(contentsOf: entries, at: at)
		selectedIndex = at + entries.count - 1
		relayout()
		write([item.text])
		scrollToSelected()
	}
	
	override func addImages(_ images: [NSImage]) {
		insertEntries(newImageLines(images).compactMap { $0.ids.first })
	}
	
	override func addVideos(_ urls: [String]) {
		insertEntries(urls.map { ViralMedia.make(url: $0, thumbnail: nil) })
	}
	
	func setThumbnail(_ image: NSImage, at index: Int) {
		guard index < item.ids.count, let settings else { return }
		let entry = item.ids[index]
		guard ViralMedia.isVideo(entry), ViralMedia.thumbnail(entry) == nil,
			  let id = ViralImages.add(image, settings: settings) else { return }
		item.ids[index] = ViralMedia.make(url: ViralMedia.url(entry), thumbnail: id)
		write([item.text])
	}
	
	func removeSelected() {
		guard selectedIndex < item.ids.count else {
			host?.deleteEmbed(self)
			return
		}
		for (_, video) in videos { video.view.removeFromSuperview() }
		videos = [:]
		item.ids.remove(at: selectedIndex)
		selectedIndex = min(selectedIndex, max(item.ids.count - 1, 0))
		relayout()
		write([item.text])
	}
	
	@objc func delete(_ sender: Any?) { removeSelected() }
	@objc func removeImageFromMenu(_ sender: Any?) { removeSelected() }
	@objc func deleteCarouselFromMenu(_ sender: Any?) { host?.deleteEmbed(self) }
	@objc func toggleRounded(_ sender: Any?) {
		item.rounded.toggle()
		relayout()
		write([item.text])
	}
	@objc func setHeightFromMenu(_ sender: NSMenuItem) {
		item.height = sender.tag
		relayout()
		write([item.text])
	}
	@objc func openInBrowser(_ sender: Any?) {
		guard selectedIndex < item.ids.count, ViralMedia.isVideo(item.ids[selectedIndex]),
			  let url = URL(string: ViralMedia.url(item.ids[selectedIndex])) else { return }
		NSWorkspace.shared.open(url)
	}
	
	override func keyDown(with event: NSEvent) {
		switch event.keyCode {
		case 123:
			if selectedIndex > 0 { selectedIndex -= 1; scrollToSelected(); updateChrome() }
		case 124:
			if selectedIndex < item.ids.count - 1 { selectedIndex += 1; scrollToSelected(); updateChrome() }
		case 51, 117: removeSelected()
		default: super.keyDown(with: event)
		}
	}
	
	override func menu(for event: NSEvent) -> NSMenu? {
		window?.makeFirstResponder(self)
		let point = convert(event.locationInWindow, from: nil)
		if let i = itemFrames.firstIndex(where: { $0.offsetBy(dx: -scrollX, dy: 0).contains(point) }) {
			selectedIndex = i
			updateChrome()
		}
		let isVideo = selectedIndex < item.ids.count && ViralMedia.isVideo(item.ids[selectedIndex])
		
		let menu = NSMenu()
		let add = NSMenuItem(title: "Add Images…", action: #selector(chooseAndAddImages(_:)), keyEquivalent: "")
		add.target = self
		menu.addItem(add)
		if !item.ids.isEmpty {
			let remove = NSMenuItem(title: isVideo ? "Remove This Video" : "Remove This Image", action: #selector(removeImageFromMenu(_:)), keyEquivalent: "")
			remove.target = self
			menu.addItem(remove)
		}
		if isVideo {
			let open = NSMenuItem(title: "Open in Browser", action: #selector(openInBrowser(_:)), keyEquivalent: "")
			open.target = self
			menu.addItem(open)
			signInMenu(into: menu)
		}
		menu.addItem(NSMenuItem.separator())
		
		let heights = NSMenuItem(title: "Height", action: nil, keyEquivalent: "")
		let sub = NSMenu()
		for (title, value) in [("Small", 25), ("Medium", 40), ("Large", 60), ("Extra Large", 80)] {
			let entry = NSMenuItem(title: title, action: #selector(setHeightFromMenu(_:)), keyEquivalent: "")
			entry.tag = value
			entry.target = self
			entry.state = item.height == value ? .on : .off
			sub.addItem(entry)
		}
		heights.submenu = sub
		menu.addItem(heights)
		
		let round = NSMenuItem(title: "Rounded Corners", action: #selector(toggleRounded(_:)), keyEquivalent: "")
		round.target = self
		round.state = item.rounded ? .on : .off
		menu.addItem(round)
		menu.addItem(NSMenuItem.separator())
		
		let delete = NSMenuItem(title: "Delete Carousel", action: #selector(deleteCarouselFromMenu(_:)), keyEquivalent: "")
		delete.target = self
		menu.addItem(delete)
		return menu
	}
}

fileprivate final class ViralFlippedView: NSView {
	override var isFlipped: Bool { return true }
}
// MARK: - Text view integration (images)

public extension BeatTextView {
	
	fileprivate var embedViews: [ViralEmbedView] {
		get { return objc_getAssociatedObject(self, &ViralEmbedViewsKey) as? [ViralEmbedView] ?? [] }
		set { objc_setAssociatedObject(self, &ViralEmbedViewsKey, newValue, .OBJC_ASSOCIATION_RETAIN_NONATOMIC) }
	}
	
	fileprivate var pendingEmbedFocus: Int? {
		get { return objc_getAssociatedObject(self, &ViralPendingEmbedFocusKey) as? Int }
		set { objc_setAssociatedObject(self, &ViralPendingEmbedFocusKey, newValue, .OBJC_ASSOCIATION_RETAIN_NONATOMIC) }
	}
	
	fileprivate struct EmbedBlock {
		var range: NSRange
		var lines: [String]
		var kind: EmbedKind
	}
	
	/// Images and carousels in the document, scanned again only when the text changed
	fileprivate func embedBlocks() -> [EmbedBlock] {
		let cache = blockCache
		let length = (self.string as NSString).length
		if cache.embedKey.version == cache.version && cache.embedKey.length == length, let blocks = cache.embeds as? [EmbedBlock] { return blocks }
		let blocks = scanEmbedBlocks()
		cache.embeds = blocks
		cache.embedKey = (cache.version, length)
		return blocks
	}
	
	/// Finds image groups and carousels from the text
	fileprivate func scanEmbedBlocks() -> [EmbedBlock] {
		let ns = self.string as NSString
		var blocks: [EmbedBlock] = []
		var current: EmbedBlock? = nil
		var location = 0
		
		while location < ns.length {
			let lineRange = ns.lineRange(for: NSRange(location: location, length: 0))
			if lineRange.length == 0 { break }
			var content = lineRange
			if content.length > 0 && ns.character(at: NSMaxRange(content) - 1) == 10 { content.length -= 1 }
			
			var embed: EmbedLine? = nil
			if content.length > 10 {
				let line = ns.substring(with: content)
				if line.trimmingCharacters(in: .whitespaces).hasPrefix("![") { embed = EmbedLine.parse(line) }
				
				if let embed {
					if embed.kind.isGroupItem, var block = current, block.kind == .image {
						block.lines.append(line)
						block.range.length = NSMaxRange(content) - block.range.location
						current = block
					} else {
						if let block = current { blocks.append(block) }
						current = EmbedBlock(range: content, lines: [line], kind: embed.kind.isGroupItem ? .image : .carousel)
						if embed.kind == .carousel, let block = current {
							blocks.append(block)
							current = nil
						}
					}
				}
			}
			if embed == nil, let block = current {
				blocks.append(block)
				current = nil
			}
			location = NSMaxRange(lineRange)
		}
		if let block = current { blocks.append(block) }
		return blocks
	}
	
	/// Image lines starting at the given location (a single line for a carousel)
	fileprivate func embedLines(at location: Int) -> [EmbedLine] {
		let ns = self.string as NSString
		var result: [EmbedLine] = []
		var loc = location
		while loc < ns.length {
			let lineRange = ns.lineRange(for: NSRange(location: loc, length: 0))
			if lineRange.length == 0 { break }
			var content = lineRange
			if content.length > 0 && ns.character(at: NSMaxRange(content) - 1) == 10 { content.length -= 1 }
			guard content.length > 10, let embed = EmbedLine.parse(ns.substring(with: content)) else { break }
			if embed.kind == .carousel {
				if result.isEmpty { result.append(embed) }
				break
			}
			result.append(embed)
			loc = NSMaxRange(lineRange)
		}
		return result
	}
	
	fileprivate func embedHeightAtLocation(_ location: Int) -> CGFloat? {
		let lines = embedLines(at: location)
		guard let first = lines.first else { return nil }
		if first.kind == .carousel { return ViralCarouselView.height(for: first, textWidth: tableWidth) }
		return viralGroupLayout(lines, width: tableWidth, settings: editorDelegate?.documentSettings).height
	}
	
	fileprivate func updateEmbedViews() {
		guard let lm = layoutManager, let tc = textContainer else { return }
		let blocks = embedBlocks()
		var unused = embedViews
		var ordered: [ViralEmbedView] = []
		
		for block in blocks {
			let candidates = unused.indices.filter { unused[$0].kind == block.kind }
			if let index = candidates.min(by: { abs(unused[$0].blockRange.location - block.range.location) < abs(unused[$1].blockRange.location - block.range.location) }) {
				ordered.append(unused.remove(at: index))
			} else {
				let view: ViralEmbedView = (block.kind == .image) ? ViralImageGroupView(host: self) : ViralCarouselView(host: self)
				addSubview(view)
				ordered.append(view)
			}
		}
		for view in unused {
			if window?.firstResponder === view { window?.makeFirstResponder(self) }
			view.removeFromSuperview()
		}
		
		let width = tableWidth
		let ns = self.string as NSString
		
		for (i, block) in blocks.enumerated() {
			let view = ordered[i]
			view.blockRange = block.range
			
			// Carousels run from edge to edge of the page, everything else stays within the text
			let isCarousel = (block.kind == .carousel)
			let viewWidth = isCarousel ? tc.size.width - 4 : width
			var widthChanged = view.embedWidth != viewWidth
			view.embedWidth = viewWidth
			if let carousel = view as? ViralCarouselView, carousel.textInset != tc.lineFragmentPadding - 2 {
				carousel.textInset = tc.lineFragmentPadding - 2
				widthChanged = true
			}
			
			let text = ns.substring(with: block.range)
			if text != view.sourceText || widthChanged {
				view.load(text: text, lines: block.lines)
			}
			
			let glyph = lm.glyphIndexForCharacter(at: block.range.location)
			let lineRect = lm.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
			let origin = textContainerOrigin
			let frame = isCarousel
				? NSRect(x: origin.x + 2, y: origin.y + lineRect.minY, width: tc.size.width - 4, height: view.totalHeight)
				: NSRect(x: origin.x + tc.lineFragmentPadding, y: origin.y + lineRect.minY, width: width + 24, height: view.totalHeight)
			if view.frame != frame { view.frame = frame }
			let folded = isFolded(block.range.location)
			if view.isHidden != folded { view.isHidden = folded }
		}
		
		embedViews = ordered
		
		if let pending = pendingEmbedFocus, let view = ordered.first(where: { $0.blockRange.location == pending }) {
			pendingEmbedFocus = nil
			view.activate(atEnd: false)
		}
	}
	
	/// Replaces block text in the document. Only changed lines are replaced, which keeps the parser happy.
	fileprivate func replaceBlockText(_ range: NSRange, with text: String) {
		guard let textActions = editorDelegate?.textActions else { return }
		let ns = self.string as NSString
		guard NSMaxRange(range) <= ns.length else { return }
		
		isWritingTable = true
		defer { isWritingTable = false }
		if window?.firstResponder !== self {
			self.setSelectedRange(NSRange(location: range.location, length: 0))
		}
		
		let old = ns.substring(with: range).components(separatedBy: "\n")
		let new = text.components(separatedBy: "\n")
		
		var starts: [Int] = []
		var pos = range.location
		for line in old { starts.append(pos); pos += (line as NSString).length + 1 }
		
		var prefix = 0
		while prefix < min(old.count, new.count) && old[prefix] == new[prefix] { prefix += 1 }
		var suffix = 0
		while suffix < min(old.count, new.count) - prefix && old[old.count - 1 - suffix] == new[new.count - 1 - suffix] { suffix += 1 }
		
		if old.count == new.count {
			for i in stride(from: old.count - 1 - suffix, through: prefix, by: -1) where old[i] != new[i] {
				textActions.replace(NSRange(location: starts[i], length: (old[i] as NSString).length), with: new[i])
			}
		} else {
			let oldMid = Array(old[prefix..<(old.count - suffix)])
			let newMid = Array(new[prefix..<(new.count - suffix)])
			
			if oldMid.count > 0 {
				let first = starts[prefix]
				let lastIndex = old.count - suffix - 1
				let end = starts[lastIndex] + (old[lastIndex] as NSString).length
				if newMid.count > 0 {
					textActions.replace(NSRange(location: first, length: end - first), with: newMid.joined(separator: "\n"))
				} else if prefix > 0 {
					textActions.replace(NSRange(location: first - 1, length: end - first + 1), with: "")
				} else {
					textActions.replace(NSRange(location: first, length: end - first + 1), with: "")
				}
			} else if prefix < old.count {
				textActions.replace(NSRange(location: starts[prefix], length: 0), with: newMid.joined(separator: "\n") + "\n")
			} else {
				textActions.replace(NSRange(location: NSMaxRange(range), length: 0), with: "\n" + newMid.joined(separator: "\n"))
			}
		}
		
		// The block height lives on its first line, so make sure that line is laid out again
		let length = (self.string as NSString).length
		if range.location < length {
			layoutManager?.invalidateLayout(forCharacterRange: NSRange(location: range.location, length: 1), actualCharacterRange: nil)
		}
	}
	
	fileprivate func deleteEmbed(_ view: ViralEmbedView) {
		guard let textActions = editorDelegate?.textActions else { return }
		let ns = self.string as NSString
		var range = view.blockRange
		guard NSMaxRange(range) <= ns.length else { return }
		if NSMaxRange(range) < ns.length { range.length += 1 }
		
		embedViews.removeAll { $0 === view }
		window?.makeFirstResponder(self)
		view.removeFromSuperview()
		
		isWritingTable = true
		textActions.replace(range, with: "")
		isWritingTable = false
		self.setSelectedRange(NSRange(location: min(range.location, (self.string as NSString).length), length: 0))
		scheduleTableUpdate()
	}
	
	/// Moves the caret out of an image block into the script
	fileprivate func exitEmbed(_ view: ViralEmbedView, below: Bool) {
		guard let textActions = editorDelegate?.textActions else { return }
		window?.makeFirstResponder(self)
		
		let range = view.blockRange
		if below {
			let length = (self.string as NSString).length
			if NSMaxRange(range) >= length {
				textActions.replace(NSRange(location: length, length: 0), with: "\n")
			}
			let ns = self.string as NSString
			let target = min(NSMaxRange(range) + 1, ns.length)
			self.setSelectedRange(NSRange(location: target, length: 0))
		} else {
			if range.location == 0 {
				textActions.replace(NSRange(location: 0, length: 0), with: "\n")
				self.setSelectedRange(NSRange(location: 0, length: 0))
			} else {
				self.setSelectedRange(NSRange(location: range.location - 1, length: 0))
			}
		}
		scrollRangeToVisible(self.selectedRange())
	}
	
	/// Inserts image lines at the caret. Images go on their own lines, after the current line if it has text.
	fileprivate func insertEmbedLines(_ lines: [String], focus: Bool = false) {
		guard let textActions = editorDelegate?.textActions, !lines.isEmpty else { return }
		let ns = self.string as NSString
		var location = min(self.selectedRange().location, ns.length)
		// Never insert inside a table, put the images after it
		for view in tableViews where location >= view.tableRange.location && location <= NSMaxRange(view.tableRange) {
			location = NSMaxRange(view.tableRange)
		}
		var lineOnly = ns.lineRange(for: NSRange(location: location, length: 0))
		if lineOnly.length > 0 && ns.character(at: NSMaxRange(lineOnly) - 1) == 10 { lineOnly.length -= 1 }
		let current = ns.substring(with: lineOnly)
		
		let block = lines.joined(separator: "\n")
		var text = block
		var range: NSRange
		var offset = 0
		
		if current.trimmingCharacters(in: .whitespaces).isEmpty {
			range = lineOnly
		} else if EmbedLine.parse(current)?.kind.isGroupItem == true && lines.allSatisfy({ EmbedLine.parse($0)?.kind.isGroupItem == true }) {
			range = NSRange(location: NSMaxRange(lineOnly), length: 0)
			text = "\n" + text
			offset = 1
		} else {
			range = NSRange(location: NSMaxRange(lineOnly), length: 0)
			text = "\n\n" + text
			offset = 2
		}
		
		let after = NSMaxRange(range)
		if after >= ns.length || ns.character(at: after) != 10 { text += "\n" }
		
		textActions.replace(range, with: text)
		
		let start = range.location + offset
		if focus {
			pendingEmbedFocus = start
		} else {
			let end = min(start + (block as NSString).length + 1, (self.string as NSString).length)
			self.setSelectedRange(NSRange(location: end, length: 0))
		}
		scheduleTableUpdate()
	}
	
	fileprivate func insertImages(_ images: [NSImage]) {
		guard let settings = editorDelegate?.documentSettings else { return }
		let lines = images.compactMap { image -> String? in
			guard let id = ViralImages.add(image, settings: settings) else { return nil }
			return EmbedLine(kind: .image, ids: [id], width: ViralImages.defaultWidth(image, textWidth: tableWidth)).text
		}
		insertEmbedLines(lines)
	}
	
	fileprivate func insertVideos(_ urls: [String]) {
		let lines = urls.map { EmbedLine(kind: .video, ids: [ViralMedia.make(url: $0, thumbnail: nil)], width: 33).text }
		insertEmbedLines(lines)
	}
	
	fileprivate func insertCarousel() {
		insertEmbedLines([EmbedLine(kind: .carousel, ids: [], width: 100, height: 40).text], focus: true)
	}
	
	fileprivate func chooseImages(_ completion: @escaping ([NSImage]) -> Void) {
		let panel = NSOpenPanel()
		panel.allowsMultipleSelection = true
		panel.canChooseDirectories = false
		panel.canChooseFiles = true
		panel.allowedContentTypes = [.image]
		panel.prompt = "Add"
		
		let handler: (NSApplication.ModalResponse) -> Void = { response in
			guard response == .OK else { return }
			let images = panel.urls.compactMap { NSImage(contentsOf: $0) }
			if !images.isEmpty { completion(images) }
		}
		if let window { panel.beginSheetModal(for: window, completionHandler: handler) }
		else { handler(panel.runModal()) }
	}
	
	/// `/image` opens a file dialog, `/carousel` inserts a carousel
	fileprivate func insertEmbedFromCommand() -> Bool {
		let ns = self.string as NSString
		var lineRange = ns.lineRange(for: NSRange(location: self.selectedRange().location, length: 0))
		if lineRange.length > 0 && ns.character(at: NSMaxRange(lineRange) - 1) == 10 { lineRange.length -= 1 }
		let command = ns.substring(with: lineRange).trimmingCharacters(in: .whitespaces).lowercased()
		guard let textActions = editorDelegate?.textActions else { return false }
		
		if command == "/carousel" {
			textActions.replace(lineRange, with: "")
			self.setSelectedRange(NSRange(location: lineRange.location, length: 0))
			insertCarousel()
			return true
		}
		if command == "/image" || command == "/images" {
			textActions.replace(lineRange, with: "")
			self.setSelectedRange(NSRange(location: lineRange.location, length: 0))
			chooseImages { [weak self] images in self?.insertImages(images) }
			return true
		}
		return false
	}
	
	/// Called from `paste:`. Returns `true` if images were pasted.
	@objc func pasteImagesIfNeeded(_ pasteboard: NSPasteboard) -> Bool {
		let links = viralVideoLinks(from: pasteboard)
		if let embed = window?.firstResponder as? ViralEmbedView, embed.host === self {
			if !links.isEmpty { embed.addVideos(links); return true }
			let images = viralImages(from: pasteboard)
			if images.isEmpty { return false }
			embed.addImages(images)
			return true
		}
		if !links.isEmpty {
			insertVideos(links)
			return true
		}
		let images = viralImages(from: pasteboard)
		guard !images.isEmpty else { return false }
		insertImages(images)
		return true
	}
	
	/// Called from `performDragOperation:`. Returns `true` if images were dropped.
	@objc func dropImagesIfNeeded(_ sender: NSDraggingInfo) -> Bool {
		let pasteboard = sender.draggingPasteboard
		let links = viralVideoLinks(from: pasteboard)
		let images = links.isEmpty ? viralImages(from: pasteboard) : []
		guard !links.isEmpty || !images.isEmpty else { return false }
		
		let point = convert(sender.draggingLocation, from: nil)
		if let view = embedViews.first(where: { $0.frame.contains(point) }) {
			if links.isEmpty { view.addImages(images) } else { view.addVideos(links) }
			return true
		}
		
		let index = characterIndexForInsertion(at: point)
		window?.makeFirstResponder(self)
		setSelectedRange(NSRange(location: min(index, (self.string as NSString).length), length: 0))
		if links.isEmpty { insertImages(images) } else { insertVideos(links) }
		return true
	}
	
	@objc func viralInsertImage(_ sender: Any?) {
		chooseImages { [weak self] images in self?.insertImages(images) }
	}
	
	@objc func viralInsertCarousel(_ sender: Any?) {
		insertCarousel()
	}
}


// MARK: - "Save As:" in the title page
/*
 
 Write `Save As: Name` in the title page (like `Title:`), and the document is saved as `Name.fountain`
 and kept saved while you write. Changing the name renames the file.
 
 Untitled documents go to a folder chosen once (Documents by default). The folder is remembered.
 
 */

fileprivate var ViralSaveButtonKey: UInt8 = 0
fileprivate let ViralSaveFolderBookmarkKey = "ViralSaveFolderBookmark"
fileprivate var ViralSaveFolderAccess: URL? = nil
fileprivate var ViralSaveFolderAsking = false

public extension BeatTextView {
	
	/// Range of the title page `Save As:` line (without its line break)
	fileprivate var saveAsLineRange: NSRange? {
		let ns = self.string as NSString
		var location = 0
		var count = 0
		while location < ns.length && count < 40 {
			let lineRange = ns.lineRange(for: NSRange(location: location, length: 0))
			if lineRange.length == 0 { break }
			var content = lineRange
			if content.length > 0 && ns.character(at: NSMaxRange(content) - 1) == 10 { content.length -= 1 }
			let line = ns.substring(with: content).trimmingCharacters(in: .whitespaces)
			if line.isEmpty { break }
			if line.lowercased().hasPrefix("save as:") { return content }
			location = NSMaxRange(lineRange)
			count += 1
		}
		return nil
	}
	
	/// The `Save As:` value from the title page, cleaned up to be a file name
	fileprivate var saveAsName: String? {
		guard let range = saveAsLineRange else { return nil }
		let line = (self.string as NSString).substring(with: range).trimmingCharacters(in: .whitespaces)
		var name = String(line.dropFirst(8)).trimmingCharacters(in: .whitespaces)
		for bad in ["/", ":", "\\", "?", "*", "\"", "<", ">", "|"] { name = name.replacingOccurrences(of: bad, with: "-") }
		if name.lowercased().hasSuffix(".fountain") { name = String(name.dropLast(9)) }
		name = name.trimmingCharacters(in: CharacterSet(charactersIn: " ."))
		return name.isEmpty ? nil : String(name.prefix(120))
	}
	
	// MARK: Save / Update button
	
	/// A small button at the end of the `Save As:` line. "Save" for a new document, "Update" when the name changed.
	/// Hidden when the file already has that name.
	fileprivate func updateSaveAsButton() {
		let existing = objc_getAssociatedObject(self, &ViralSaveButtonKey) as? NSButton
		guard let range = saveAsLineRange, let name = saveAsName,
			  let lm = layoutManager, let tc = textContainer,
			  let document = window?.windowController?.document as? NSDocument
		else { existing?.isHidden = true; return }
		
		let current = document.fileURL?.deletingPathExtension().lastPathComponent
		if current == name { existing?.isHidden = true; return }
		
		let button: NSButton
		if let existing { button = existing } else {
			button = NSButton(title: "Save", target: self, action: #selector(viralSaveAsButtonPressed(_:)))
			button.bezelStyle = .rounded
			button.controlSize = .small
			button.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
			button.toolTip = "Save the document under this name (or press Return on this line)"
			addSubview(button)
			objc_setAssociatedObject(self, &ViralSaveButtonKey, button, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
		}
		let title = (document.fileURL == nil) ? "Save" : "Update"
		if button.title != title { button.title = title }
		button.sizeToFit()
		
		// Right after the end of the line's text
		let glyphs = lm.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
		var textRect = lm.boundingRect(forGlyphRange: glyphs, in: tc)
		if textRect.isEmpty { textRect = lm.lineFragmentUsedRect(forGlyphAt: max(glyphs.location, 0), effectiveRange: nil) }
		let origin = textContainerOrigin
		let size = button.frame.size
		var x = origin.x + textRect.maxX + 10
		x = min(x, origin.x + tc.size.width - size.width)
		let frame = NSRect(x: x, y: origin.y + textRect.midY - size.height / 2, width: size.width, height: size.height)
		if button.frame != frame { button.frame = frame }
		button.isHidden = false
	}
	
	@objc fileprivate func viralSaveAsButtonPressed(_ sender: NSButton) {
		performSaveAs()
	}
	
	fileprivate func performSaveAs() {
		guard let name = saveAsName,
			  let document = window?.windowController?.document as? NSDocument
		else { return }
		
		let type = document.fileType ?? "Fountain script"
		let fileName = name + ".fountain"
		
		if let current = document.fileURL {
			if current.lastPathComponent == fileName {
				// Same name, just keep it saved
				if document.isDocumentEdited { document.save(nil) }
				return
			}
			// Rename next to the current file
			let target = current.deletingLastPathComponent().appendingPathComponent(fileName)
			if FileManager.default.fileExists(atPath: target.path) {
				if let window {
					let alert = NSAlert()
					alert.messageText = "\u{201C}\(fileName)\u{201D} already exists in this folder"
					alert.informativeText = "Pick another name in the Save As line."
					alert.beginSheetModal(for: window)
				}
				return
			}
			// Save under the new name, then remove the old file (moving an open document can trip NSDocument's file access checks)
			document.save(to: target, ofType: type, for: .saveAsOperation) { [weak self] error in
				if error != nil {
					// No access to that folder, save into the Viral folder instead
					DispatchQueue.main.async { self?.saveIntoViralFolder(document, fileName: fileName, type: type) }
				} else {
					if document.fileURL == target { try? FileManager.default.removeItem(at: current) }
					self?.updateSaveAsButton()
				}
			}
		} else {
			saveIntoViralFolder(document, fileName: fileName, type: type)
		}
	}
	
	fileprivate func saveIntoViralFolder(_ document: NSDocument, fileName: String, type: String) {
		viralSaveFolder { folder in
			guard let folder else { return }
			var target = folder.appendingPathComponent(fileName)
			var n = 2
			let base = (fileName as NSString).deletingPathExtension
			while FileManager.default.fileExists(atPath: target.path) && target != document.fileURL {
				target = folder.appendingPathComponent("\(base) \(n).fountain")
				n += 1
			}
			document.save(to: target, ofType: type, for: .saveAsOperation) { [weak self] error in
				if let error { NSLog("Viral: Save As failed: %@", error.localizedDescription) }
				self?.updateSaveAsButton()
			}
		}
	}
	
	/// The folder for `Save As:` documents. Asked once, then remembered.
	fileprivate func viralSaveFolder(_ completion: @escaping (URL?) -> Void) {
		if let folder = ViralSaveFolderAccess { completion(folder); return }
		
		if let data = UserDefaults.standard.data(forKey: ViralSaveFolderBookmarkKey) {
			var stale = false
			if let url = try? URL(resolvingBookmarkData: data, options: [.withSecurityScope], relativeTo: nil, bookmarkDataIsStale: &stale) {
				if url.startAccessingSecurityScopedResource() {
					ViralSaveFolderAccess = url
					if stale, let fresh = try? url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil) {
						UserDefaults.standard.set(fresh, forKey: ViralSaveFolderBookmarkKey)
					}
					completion(url)
					return
				}
			}
		}
		
		guard !ViralSaveFolderAsking, let window else { completion(nil); return }
		ViralSaveFolderAsking = true
		
		let panel = NSOpenPanel()
		panel.canChooseDirectories = true
		panel.canChooseFiles = false
		panel.canCreateDirectories = true
		panel.allowsMultipleSelection = false
		panel.prompt = "Save Here"
		panel.message = "Choose where Viral saves documents with a \u{201C}Save As:\u{201D} name. You only need to do this once."
		panel.directoryURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
		panel.beginSheetModal(for: window) { response in
			ViralSaveFolderAsking = false
			guard response == .OK, let url = panel.url else { completion(nil); return }
			if let data = try? url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil) {
				UserDefaults.standard.set(data, forKey: ViralSaveFolderBookmarkKey)
			}
			_ = url.startAccessingSecurityScopedResource()
			ViralSaveFolderAccess = url
			completion(url)
		}
	}
}


// MARK: - Page width

/// The width of the editor page, in characters. Printing keeps the paper width.
@objc final class ViralPageWidth: NSObject, NSMenuItemValidation {
	@objc static let shared = ViralPageWidth()
	static let presets: [(title: String, width: Int)] = [("Narrow", 55), ("Normal", 67), ("Wide", 80), ("Extra Wide", 95)]
	static let minimum = 45
	static let maximum = 110
	private var menuInstalled = false
	
	var current: Int { return BeatUserDefaults.shared().getInteger(BeatSettingViralPageWidth) }
	
	func set(_ value: Int) {
		let width = min(max(value, ViralPageWidth.minimum), ViralPageWidth.maximum)
		guard width != current else { return }
		BeatUserDefaults.shared().save(NSNumber(value: width), forKey: BeatSettingViralPageWidth)
		apply()
	}
	
	/// Re-reads the styles in every open document and lays the page out again
	func apply() {
		for document in NSDocumentController.shared.documents {
			let object = document as NSObject
			if object.responds(to: NSSelectorFromString("resetStyles")) { object.perform(NSSelectorFromString("resetStyles")) }
			if object.responds(to: NSSelectorFromString("formatting")),
			   let formatting = object.value(forKey: "formatting") as? NSObject, formatting.responds(to: NSSelectorFromString("formatAllLines")) {
				formatting.perform(NSSelectorFromString("formatAllLines"))
			}
			if object.responds(to: NSSelectorFromString("updateLayout")) { object.perform(NSSelectorFromString("updateLayout")) }
		}
	}
	
	@objc func choosePreset(_ sender: NSMenuItem) { set(sender.tag) }
	@objc func wider(_ sender: Any?) { set(current + 5) }
	@objc func narrower(_ sender: Any?) { set(current - 5) }
	
	func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
		if menuItem.action == #selector(choosePreset(_:)) { menuItem.state = (menuItem.tag == current) ? .on : .off }
		if menuItem.action == #selector(wider(_:)) { return current < ViralPageWidth.maximum }
		if menuItem.action == #selector(narrower(_:)) { return current > ViralPageWidth.minimum }
		return true
	}
	
	/// Adds View > Page Width to the main menu
	@objc func installMenu() {
		guard !menuInstalled, let viewMenu = NSApp.mainMenu?.items.first(where: { $0.submenu?.title == "View" || $0.title == "View" })?.submenu else { return }
		menuInstalled = true
		
		let submenu = NSMenu(title: "Page Width")
		for preset in ViralPageWidth.presets {
			let item = NSMenuItem(title: preset.title, action: #selector(choosePreset(_:)), keyEquivalent: "")
			item.tag = preset.width
			item.target = self
			submenu.addItem(item)
		}
		submenu.addItem(NSMenuItem.separator())
		let wider = NSMenuItem(title: "Wider", action: #selector(wider(_:)), keyEquivalent: "]")
		wider.keyEquivalentModifierMask = [.command, .option]
		wider.target = self
		submenu.addItem(wider)
		let narrower = NSMenuItem(title: "Narrower", action: #selector(narrower(_:)), keyEquivalent: "[")
		narrower.keyEquivalentModifierMask = [.command, .option]
		narrower.target = self
		submenu.addItem(narrower)
		
		let item = NSMenuItem(title: "Page Width", action: nil, keyEquivalent: "")
		item.submenu = submenu
		viewMenu.addItem(NSMenuItem.separator())
		viewMenu.addItem(item)
	}
}

// MARK: - Info

/// The Info popover: page width and everything you can do in Viral
@objc final class ViralInfoController: NSViewController {
	private let slider = NSSlider(value: 67, minValue: Double(ViralPageWidth.minimum), maxValue: Double(ViralPageWidth.maximum), target: nil, action: nil)
	private let valueLabel = NSTextField(labelWithString: "")
	
	@objc static func show(from button: NSView) {
		let popover = NSPopover()
		popover.behavior = .transient
		popover.contentViewController = ViralInfoController()
		popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
	}
	
	override func loadView() {
		let width: CGFloat = 470
		let height: CGFloat = 560
		let root = NSView(frame: NSRect(x: 0, y: 0, width: width, height: height))
		
		let title = NSTextField(labelWithString: "Page width")
		title.font = NSFont.systemFont(ofSize: 12, weight: .semibold)
		title.frame = NSRect(x: 16, y: height - 34, width: 90, height: 18)
		root.addSubview(title)
		
		slider.frame = NSRect(x: 104, y: height - 36, width: 250, height: 22)
		slider.integerValue = ViralPageWidth.shared.current
		slider.target = self
		slider.action = #selector(sliderChanged(_:))
		slider.isContinuous = false
		root.addSubview(slider)
		
		valueLabel.frame = NSRect(x: 362, y: height - 34, width: 92, height: 18)
		valueLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
		valueLabel.textColor = .secondaryLabelColor
		root.addSubview(valueLabel)
		updateValueLabel()
		
		let separator = NSBox(frame: NSRect(x: 16, y: height - 50, width: width - 32, height: 1))
		separator.boxType = .separator
		root.addSubview(separator)
		
		let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: width, height: height - 54))
		scroll.hasVerticalScroller = true
		scroll.drawsBackground = false
		scroll.borderType = .noBorder
		let text = NSTextView(frame: NSRect(x: 0, y: 0, width: width, height: height - 54))
		text.isEditable = false
		text.isSelectable = true
		text.drawsBackground = false
		text.textContainerInset = NSSize(width: 12, height: 10)
		text.textStorage?.setAttributedString(ViralInfoController.guide())
		scroll.documentView = text
		root.addSubview(scroll)
		
		self.view = root
	}
	
	private func updateValueLabel() {
		let width = ViralPageWidth.shared.current
		let preset = ViralPageWidth.presets.first(where: { $0.width == width })?.title
		valueLabel.stringValue = preset.map { "\(width) · \($0)" } ?? "\(width) characters"
	}
	
	@objc private func sliderChanged(_ sender: NSSlider) {
		ViralPageWidth.shared.set(sender.integerValue)
		updateValueLabel()
	}
	
	// MARK: Guide text
	
	static func guide() -> NSAttributedString {
		let result = NSMutableAttributedString()
		let paragraph = NSMutableParagraphStyle()
		paragraph.tabStops = [NSTextTab(textAlignment: .left, location: 150)]
		paragraph.headIndent = 150
		paragraph.paragraphSpacing = 3
		let headerStyle = NSMutableParagraphStyle()
		headerStyle.paragraphSpacingBefore = 10
		headerStyle.paragraphSpacing = 4
		
		func header(_ text: String) {
			result.append(NSAttributedString(string: text + "\n", attributes: [
				.font: NSFont.systemFont(ofSize: 13, weight: .semibold), .foregroundColor: NSColor.labelColor, .paragraphStyle: headerStyle
			]))
		}
		func row(_ keys: String, _ text: String) {
			result.append(NSAttributedString(string: keys, attributes: [
				.font: NSFont.systemFont(ofSize: 12, weight: .medium), .foregroundColor: NSColor.labelColor, .paragraphStyle: paragraph
			]))
			result.append(NSAttributedString(string: "\t" + text + "\n", attributes: [
				.font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.secondaryLabelColor, .paragraphStyle: paragraph
			]))
		}
		
		header("Writing")
		row("INT. EXT. BRAND\nFACT THOUGHT", "Start a line with one of these to make a scene heading")
		row("Title:", "Title page. Put it on the first line")
		row("/title  ↩", "Add a title page at the top")
		row("Save As: Name", "Saves the document as Name. Press ↩ on the line, or click Save / Update next to it")
		row("Authored by:", "Prints \u{201C}Authored by\u{201D} and the name under the title. Also: Written by, Created by, Author")
		row("Credit: Source:", "More lines under the title")
		row("Draft date: Date:", "Bottom right of the title page")
		row("Contact: Email:", "Bottom left of the title page")
		row("Any Key: value", "Anything else (Client, Brand, Version, Notes\u{2026}) prints bottom left")
		
		header("Blocks")
		row("/table  ↩", "Insert a table. /table 4x3 sets columns and rows")
		row("/image  ↩", "Add images from files")
		row("/carousel  ↩", "Insert a carousel")
		row("⌘V or drop", "Images, or links to YouTube, Vimeo, Instagram and Facebook videos")
		row("Right-click", "Insert Image, Insert Carousel or Insert Table")
		
		header("Tables")
		row("⇥   ⇧⇥", "Next / previous cell. Tab on the last cell adds a row")
		row("↩", "Cell below. Adds a row at the end")
		row("⇧↩", "New line inside a cell")
		row("↑  ↓", "Move between rows, or out of the table")
		row("⎋", "Leave the table")
		row("Right-click", "Add or delete rows and columns, or delete the table")
		
		header("Images and videos")
		row("Click", "Select (videos: use the ••• button)")
		row("Drag the corner", "Resize. The shape stays the same")
		row("⌫", "Delete the selected image or video")
		row("←  →", "Select the previous / next one")
		row("Right-click", "Size, rounded corners, open in browser, sign in to Instagram or Facebook")
		
		header("Carousels")
		row("‹  ›  or swipe", "Scroll through the images")
		row("Drag the corner", "Change the height")
		row("Right-click", "Height, rounded corners, add or remove images")
		
		header("Page")
		row("⌥⌘]   ⌥⌘[", "Wider / narrower page (View ▸ Page Width)")
		row("⌘+   ⌘−", "Zoom in / out")
		
		// Everything else comes from the menus, so it's always up to date
		for top in NSApp.mainMenu?.items ?? [] {
			guard let menu = top.submenu else { continue }
			var rows: [(String, String)] = []
			collectShortcuts(menu, into: &rows)
			guard !rows.isEmpty else { continue }
			header(top.title.isEmpty ? menu.title : top.title)
			for (keys, title) in rows { row(keys, title) }
		}
		return result
	}
	
	private static func collectShortcuts(_ menu: NSMenu, into rows: inout [(String, String)]) {
		for item in menu.items where !item.isHidden && !item.isSeparatorItem {
			if let submenu = item.submenu {
				collectShortcuts(submenu, into: &rows)
			} else if let keys = shortcut(for: item), !item.title.isEmpty {
				rows.append((keys, item.title))
			}
		}
	}
	
	private static func shortcut(for item: NSMenuItem) -> String? {
		let key = item.keyEquivalent
		guard !key.isEmpty else { return nil }
		let mask = item.keyEquivalentModifierMask
		var shift = mask.contains(.shift)
		if key.count == 1, key.uppercased() == key, key.lowercased() != key { shift = true }
		
		var symbol: String
		switch key.unicodeScalars.first.map({ Int($0.value) }) ?? 0 {
		case 0x0D, 0x03: symbol = "↩"
		case 0x1B: symbol = "⎋"
		case 0x09: symbol = "⇥"
		case 0x08, 0x7F: symbol = "⌫"
		case 0x20: symbol = "Space"
		case NSUpArrowFunctionKey: symbol = "↑"
		case NSDownArrowFunctionKey: symbol = "↓"
		case NSLeftArrowFunctionKey: symbol = "←"
		case NSRightArrowFunctionKey: symbol = "→"
		case NSF1FunctionKey...NSF12FunctionKey: symbol = "F\((Int(key.unicodeScalars.first!.value) - NSF1FunctionKey) + 1)"
		default: symbol = key.uppercased()
		}
		
		var result = ""
		if mask.contains(.control) { result += "⌃" }
		if mask.contains(.option) { result += "⌥" }
		if shift { result += "⇧" }
		if mask.contains(.command) { result += "⌘" }
		return result + symbol
	}
}
