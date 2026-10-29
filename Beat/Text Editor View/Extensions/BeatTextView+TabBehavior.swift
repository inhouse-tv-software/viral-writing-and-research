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

fileprivate enum BTMetrics {
	static let paddingX: CGFloat = 8
	static let paddingY: CGFloat = 5
	static let marginTop: CGFloat = 8
	/// Room for the "add row" button below the table
	static let marginBottom: CGFloat = 26
	static let addButtonSize: CGFloat = 18
	static let border: CGFloat = 1
}

// MARK: Debug log

fileprivate func btLog(_ message: @autoclosure () -> String) {
	#if DEBUG
	NSLog("[BeatTables] %@", message())
	#endif
}

// MARK: Table model

fileprivate struct BeatTableModel {
	var rows: [[String]]
	
	var columnCount: Int { return rows.first?.count ?? 1 }
	func emptyRow() -> [String] { return Array(repeating: "", count: columnCount) }
	
	static func isRow(_ s: String) -> Bool {
		let t = s.trimmingCharacters(in: .whitespaces)
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
	
	/// Finds tables from the text itself (the parser can lag behind right after an edit)
	fileprivate func tableBlocks() -> [BTBlock] {
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
		btLog("HEIGHT at \(location) lines=\(strings.count) h=\(Int(height))")
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
	}
	
	// MARK: Placing table views
	
	fileprivate func updateTableViews() {
		guard let lm = layoutManager, let tc = textContainer else { return }
		let blocks = tableBlocks()
		var views = tableViews
		
		btLog("UPDATE blocks=\(blocks.map { "\($0.range.location)+\($0.range.length):\($0.lines.count)" }) views=\(views.map { $0.tableRange.location }) fr=\(String(describing: type(of: window?.firstResponder ?? self)))")
		
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
			// Don't throw away a table that's being edited
			if let responder = window?.firstResponder as? BeatTableCellView, responder.table === view {
				btLog("KEEP edited view")
				ordered.append(view)
				continue
			}
			view.removeFromSuperview()
		}
		views = ordered
		
		let width = tableWidth
		let ns = self.string as NSString
		
		for (i, block) in blocks.enumerated() {
			let view = views[i]
			
			view.tableRange = block.range
			view.font = tableFont
			view.textColor = self.textColor ?? .textColor
			view.tableWidth = width
			
			let text = ns.substring(with: block.range)
			if text != view.sourceText || view.cells.isEmpty {
				view.load(text: text, lines: block.lines)
			} else {
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
		}
		
		tableViews = views
		updateEmbedViews()
		
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
		guard NSMaxRange(view.tableRange) <= ns.length else { return }
		
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
		btLog("REPLACE \(range.location)+\(range.length) old=\(old.count) new=\(new.count) prefix=\(prefix) suffix=\(suffix)")
		
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
		
		// Keep typing in the cell even if something moved focus while the document was updated
		if let activeCell, let cellSelection, window?.firstResponder !== activeCell {
			btLog("FOCUS restored")
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
		window?.makeFirstResponder(self)
		textActions.replace(range, with: "")
		self.setSelectedRange(NSRange(location: min(range.location, (self.string as NSString).length), length: 0))
		scheduleTableUpdate()
	}
	
	/// Moves the caret out of the table into the script
	fileprivate func exitTable(_ view: BeatTableView, below: Bool) {
		guard let textActions = editorDelegate?.textActions else { return }
		window?.makeFirstResponder(self)
		
		let range = view.tableRange
		if below {
			var end = NSMaxRange(range)
			let length = (self.string as NSString).length
			if end >= length {
				// Table is at the end of the document, add room below it
				textActions.replace(NSRange(location: length, length: 0), with: "\n\n")
				end = NSMaxRange(range)
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
				btLog("CARET INTO TABLE at \(selection.location)")
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
		
		// Return on a `/table` line inserts a table
		if (event.keyCode == 36 || event.keyCode == 76) && flags.isEmpty && selection.length == 0 {
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
			for view in tableViews where selection.location > view.tableRange.location && selection.location < NSMaxRange(view.tableRange) {
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

// MARK: - Images and carousels
/*
 
 Images are stored in the document settings (base64, key `ViralImages`) and referenced from the text:
 
 ![image](viral:ID 50)                  an image, 50% of the text width
 ![carousel](viral:ID1,ID2,ID3 100)     a carousel
 
 Consecutive image lines are laid out side by side when they fit, otherwise they wrap to the next row.
 Like tables, the text is hidden in the editor and a view is drawn on top of it.
 
 Paste images anywhere, or type `/image` or `/carousel` and press Return.
 
 */

fileprivate let ViralImagesKey = "ViralImages"
fileprivate var ViralEmbedViewsKey: UInt8 = 0
fileprivate var ViralPendingEmbedFocusKey: UInt8 = 0

fileprivate enum EMetrics {
	static let marginTop: CGFloat = 8
	static let marginBottom: CGFloat = 14
	static let carouselBottom: CGFloat = 26
	static let handle: CGFloat = 12
}

fileprivate enum EmbedKind { case image, carousel }

fileprivate struct EmbedLine {
	var kind: EmbedKind
	var ids: [String]
	var width: Int
	/// Carousel height in percent of the text width
	var height: Int = 40
	var rounded: Bool = false
	
	static let imagePrefix = "![image](viral:"
	static let carouselPrefix = "![carousel](viral:"
	
	static func parse(_ string: String) -> EmbedLine? {
		let t = string.trimmingCharacters(in: .whitespaces)
		guard t.hasSuffix(")") else { return nil }
		let kind: EmbedKind
		let prefix: String
		if t.hasPrefix(imagePrefix) { kind = .image; prefix = imagePrefix }
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
		let prefix = (kind == .image) ? EmbedLine.imagePrefix : EmbedLine.carouselPrefix
		let size = (kind == .image) ? "\(width)" : "h\(height)"
		return prefix + ids.joined(separator: ",") + " " + size + (rounded ? " r" : "") + ")"
	}
	
	static func cornerRadius(_ rect: NSRect) -> CGFloat {
		return min(12, min(rect.width, rect.height) * 0.1)
	}
}

// MARK: Image store

fileprivate enum ViralImages {
	static var cache: [String: NSImage] = [:]
	
	static func image(_ id: String, settings: BeatDocumentSettings?) -> NSImage? {
		if let image = cache[id] { return image }
		guard let dict = settings?.get(ViralImagesKey) as? [String: Any],
			  let encoded = dict[id] as? String,
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
	
	/// Height divided by width
	static func aspect(_ id: String?, settings: BeatDocumentSettings?) -> CGFloat {
		guard let id, let image = image(id, settings: settings) else { return 0.75 }
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
		dict[id] = data.base64EncodedString()
		settings.set(ViralImagesKey, as: dict)
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
	}
	required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
	
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
	
	override func becomeFirstResponder() -> Bool { redraw(); return true }
	override func resignFirstResponder() -> Bool { redraw(); return true }
	
	func redraw() {
		needsDisplay = true
		for view in subviews { view.needsDisplay = true }
	}
	
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
		let images = viralImages(from: NSPasteboard.general)
		if images.isEmpty { NSSound.beep(); return }
		addImages(images)
	}
	
	@objc func chooseAndAddImages(_ sender: Any?) {
		host?.chooseImages { [weak self] images in self?.addImages(images) }
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
	
	func drawHandle(in rect: NSRect) {
		let handle = NSRect(x: rect.maxX - EMetrics.handle, y: rect.maxY - EMetrics.handle, width: EMetrics.handle, height: EMetrics.handle)
		NSColor.controlAccentColor.setFill()
		NSBezierPath(roundedRect: handle.insetBy(dx: 1, dy: 1), xRadius: 2, yRadius: 2).fill()
		NSColor.white.setStroke()
		let line = NSBezierPath()
		line.move(to: NSPoint(x: handle.minX + 4, y: handle.maxY - 3))
		line.line(to: NSPoint(x: handle.maxX - 3, y: handle.minY + 4))
		line.lineWidth = 1
		line.stroke()
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

// MARK: Image tile

fileprivate final class ViralImageTile: NSView {
	weak var group: ViralImageGroupView?
	var index = 0
	var image: NSImage?
	var hovering = false
	var resizing = false
	var startX: CGFloat = 0
	var startWidth: CGFloat = 0
	
	override var isFlipped: Bool { return true }
	
	var handleRect: NSRect {
		return NSRect(x: bounds.maxX - EMetrics.handle, y: bounds.maxY - EMetrics.handle, width: EMetrics.handle, height: EMetrics.handle)
	}
	var isSelected: Bool { return group?.isActive == true && group?.selectedIndex == index }
	
	override func draw(_ dirtyRect: NSRect) {
		let rounded = group.map { index < $0.items.count && $0.items[index].rounded } ?? false
		let radius = rounded ? EmbedLine.cornerRadius(bounds) : 0
		if let image {
			NSGraphicsContext.saveGraphicsState()
			if radius > 0 { NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius).addClip() }
			image.draw(in: bounds, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true,
					   hints: [.interpolation: NSNumber(value: NSImageInterpolation.high.rawValue)])
			NSGraphicsContext.restoreGraphicsState()
		} else {
			(group?.color ?? .textColor).withAlphaComponent(0.08).setFill()
			bounds.fill()
			let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor]
			let text = NSAttributedString(string: "Missing image", attributes: attrs)
			text.draw(at: NSPoint(x: bounds.midX - text.size().width / 2, y: bounds.midY - text.size().height / 2))
		}
		
		if isSelected || hovering || resizing {
			let selected = isSelected || resizing
			(selected ? NSColor.controlAccentColor : (group?.color ?? .textColor).withAlphaComponent(0.3)).setStroke()
			let inset = bounds.insetBy(dx: selected ? 1 : 0.5, dy: selected ? 1 : 0.5)
			let path = NSBezierPath(roundedRect: inset, xRadius: radius, yRadius: radius)
			path.lineWidth = selected ? 2 : 1
			path.stroke()
			group?.drawHandle(in: bounds)
		}
	}
	
	override func updateTrackingAreas() {
		super.updateTrackingAreas()
		for area in trackingAreas { removeTrackingArea(area) }
		addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self, userInfo: nil))
	}
	override func mouseEntered(with event: NSEvent) { hovering = true; needsDisplay = true }
	override func mouseExited(with event: NSEvent) { hovering = false; needsDisplay = true }
	
	override func resetCursorRects() {
		addCursorRect(handleRect, cursor: .resizeLeftRight)
	}
	
	override func mouseDown(with event: NSEvent) {
		guard let group else { return }
		group.select(index)
		let point = convert(event.locationInWindow, from: nil)
		if handleRect.insetBy(dx: -3, dy: -3).contains(point) {
			resizing = true
			startX = group.convert(event.locationInWindow, from: nil).x
			startWidth = frame.width
		}
	}
	
	override func mouseDragged(with event: NSEvent) {
		guard resizing, let group else { return }
		let x = group.convert(event.locationInWindow, from: nil).x
		let width = max(40, min(group.embedWidth, startWidth + x - startX))
		group.preview(index: index, width: width)
	}
	
	override func mouseUp(with event: NSEvent) {
		guard resizing, let group else { return }
		resizing = false
		group.commit(index: index, width: frame.width)
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
			tile.image = items[i].ids.first.flatMap { ViralImages.image($0, settings: settings) }
		}
		selectedIndex = min(selectedIndex, max(items.count - 1, 0))
		relayout()
	}
	
	func relayout() {
		let frames = viralGroupLayout(items, width: embedWidth, settings: settings, override: previewWidths).frames
		for (i, tile) in tiles.enumerated() where i < frames.count {
			if tile.frame != frames[i] { tile.frame = frames[i] }
			tile.needsDisplay = true
		}
		window?.invalidateCursorRects(for: self)
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
	
	override func setWidthFromMenu(_ sender: NSMenuItem) {
		guard selectedIndex < items.count else { return }
		items[selectedIndex].width = sender.tag
		relayout()
		write(items.map { $0.text })
	}
	
	override func addImages(_ images: [NSImage]) {
		let lines = newImageLines(images)
		guard !lines.isEmpty else { return }
		let at = min(selectedIndex + 1, items.count)
		items.insert(contentsOf: lines, at: at)
		selectedIndex = at + lines.count - 1
		reloadTiles()
		write(items.map { $0.text })
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
		widthMenu(into: menu)
		menu.addItem(NSMenuItem.separator())
		let add = NSMenuItem(title: "Add Images…", action: #selector(chooseAndAddImages(_:)), keyEquivalent: "")
		add.target = self
		menu.addItem(add)
		let round = NSMenuItem(title: "Rounded Corners", action: #selector(toggleRounded(_:)), keyEquivalent: "")
		round.target = self
		round.state = (selectedIndex < items.count && items[selectedIndex].rounded) ? .on : .off
		menu.addItem(round)
		menu.addItem(NSMenuItem.separator())
		let delete = NSMenuItem(title: "Delete Image", action: #selector(deleteImageFromMenu(_:)), keyEquivalent: "")
		delete.target = self
		menu.addItem(delete)
		return menu
	}
	
	override func menu(for event: NSEvent) -> NSMenu? { return contextMenu() }
}

// MARK: Carousel

/// A horizontal strip of images at the carousel height. Scroll with the arrows or sideways on the trackpad.
fileprivate final class ViralCarouselView: ViralEmbedView {
	var item = EmbedLine(kind: .carousel, ids: [], width: 100)
	var selectedIndex = 0
	var scrollX: CGFloat = 0
	var hovering = false
	var resizing = false
	var resizeStartY: CGFloat = 0
	var resizeStartHeight: CGFloat = 0
	var previewHeight: CGFloat? = nil
	var animation: Timer? = nil
	
	let previousButton = NSButton(frame: .zero)
	let nextButton = NSButton(frame: .zero)
	let addButton = NSButton(frame: .zero)
	
	static let gap: CGFloat = 8
	static let padding: CGFloat = 6
	
	static func boxHeight(for item: EmbedLine, width: CGFloat) -> CGFloat {
		return max(60, floor(width * CGFloat(item.height) / 100))
	}
	
	static func height(for item: EmbedLine, width: CGFloat) -> CGFloat {
		return EMetrics.marginTop + boxHeight(for: item, width: width) + EMetrics.marginBottom
	}
	
	override init(host: BeatTextView) {
		super.init(host: host)
		kind = .carousel
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
	
	var boxHeight: CGFloat { return previewHeight ?? ViralCarouselView.boxHeight(for: item, width: embedWidth) }
	var boxRect: NSRect { return NSRect(x: 0, y: EMetrics.marginTop, width: embedWidth, height: boxHeight) }
	var handleRect: NSRect {
		let box = boxRect
		return NSRect(x: box.maxX - EMetrics.handle, y: box.maxY - EMetrics.handle, width: EMetrics.handle, height: EMetrics.handle)
	}
	
	override var totalHeight: CGFloat { return ViralCarouselView.height(for: item, width: embedWidth) }
	
	/// Image frames in strip coordinates (before scrolling)
	var stripFrames: [NSRect] {
		let h = boxHeight - ViralCarouselView.padding * 2
		var x = ViralCarouselView.padding
		var frames: [NSRect] = []
		for id in item.ids {
			let aspect = ViralImages.aspect(id, settings: settings)
			let w = max(20, floor(h / max(aspect, 0.05)))
			frames.append(NSRect(x: x, y: EMetrics.marginTop + ViralCarouselView.padding, width: w, height: h))
			x += w + ViralCarouselView.gap
		}
		return frames
	}
	
	var contentWidth: CGFloat {
		guard let last = stripFrames.last else { return 0 }
		return last.maxX + ViralCarouselView.padding
	}
	
	var maxScroll: CGFloat { return max(0, contentWidth - embedWidth) }
	
	override func load(text: String, lines: [String]) {
		sourceText = text
		item = EmbedLine.parse(lines.first ?? "") ?? EmbedLine(kind: .carousel, ids: [], width: 100)
		selectedIndex = min(selectedIndex, max(item.ids.count - 1, 0))
		relayout()
	}
	
	func relayout() {
		scrollX = min(max(scrollX, 0), maxScroll)
		let box = boxRect
		let size: CGFloat = 30
		previousButton.frame = NSRect(x: box.minX + 8, y: box.midY - size / 2, width: size, height: size)
		nextButton.frame = NSRect(x: box.maxX - 8 - size, y: box.midY - size / 2, width: size, height: size)
		addButton.frame = NSRect(x: box.minX + 10, y: box.minY + 10, width: 24, height: 24)
		previousButton.isHidden = scrollX <= 0.5
		nextButton.isHidden = scrollX >= maxScroll - 0.5
		window?.invalidateCursorRects(for: self)
		needsDisplay = true
	}
	
	override func draw(_ dirtyRect: NSRect) {
		let box = boxRect
		let path = NSBezierPath(roundedRect: box, xRadius: 6, yRadius: 6)
		color.withAlphaComponent(0.05).setFill()
		path.fill()
		
		if item.ids.isEmpty {
			let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.secondaryLabelColor]
			let text = NSAttributedString(string: "Paste or drop images here, or click +", attributes: attrs)
			let s = text.size()
			text.draw(at: NSPoint(x: box.midX - s.width / 2, y: box.midY - s.height / 2))
		} else {
			NSGraphicsContext.saveGraphicsState()
			path.addClip()
			for (i, frame) in stripFrames.enumerated() {
				let rect = frame.offsetBy(dx: -scrollX, dy: 0)
				guard rect.maxX > box.minX, rect.minX < box.maxX else { continue }
				let radius = item.rounded ? EmbedLine.cornerRadius(rect) : 0
				NSGraphicsContext.saveGraphicsState()
				let clip = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
				clip.addClip()
				if let image = ViralImages.image(item.ids[i], settings: settings) {
					image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true,
							   hints: [.interpolation: NSNumber(value: NSImageInterpolation.high.rawValue)])
				} else {
					color.withAlphaComponent(0.1).setFill()
					rect.fill()
				}
				NSGraphicsContext.restoreGraphicsState()
				
				if isActive && i == selectedIndex {
					NSColor.controlAccentColor.setStroke()
					let outline = NSBezierPath(roundedRect: rect.insetBy(dx: 1, dy: 1), xRadius: radius, yRadius: radius)
					outline.lineWidth = 2
					outline.stroke()
				}
			}
			NSGraphicsContext.restoreGraphicsState()
		}
		
		if isActive || hovering || resizing {
			(isActive || resizing ? NSColor.controlAccentColor : color.withAlphaComponent(0.25)).setStroke()
			let border = NSBezierPath(roundedRect: box.insetBy(dx: 0.5, dy: 0.5), xRadius: 6, yRadius: 6)
			border.lineWidth = 1
			border.stroke()
			drawHandle(in: box)
		}
	}
	
	override func updateTrackingAreas() {
		super.updateTrackingAreas()
		for area in trackingAreas { removeTrackingArea(area) }
		addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self, userInfo: nil))
	}
	override func mouseEntered(with event: NSEvent) { hovering = true; needsDisplay = true }
	override func mouseExited(with event: NSEvent) { hovering = false; needsDisplay = true }
	override func resetCursorRects() { addCursorRect(handleRect, cursor: .resizeUpDown) }
	
	override func mouseDown(with event: NSEvent) {
		window?.makeFirstResponder(self)
		let point = convert(event.locationInWindow, from: nil)
		if handleRect.insetBy(dx: -3, dy: -3).contains(point) {
			resizing = true
			resizeStartY = point.y
			resizeStartHeight = boxHeight
			return
		}
		if let i = stripFrames.firstIndex(where: { $0.offsetBy(dx: -scrollX, dy: 0).contains(point) }) {
			selectedIndex = i
			scrollToSelected()
		}
		needsDisplay = true
	}
	
	override func mouseDragged(with event: NSEvent) {
		guard resizing else { return }
		let y = convert(event.locationInWindow, from: nil).y
		previewHeight = max(60, min(embedWidth * 1.5, resizeStartHeight + y - resizeStartY))
		let height = EMetrics.marginTop + boxHeight + EMetrics.marginBottom
		if height > frame.height { setFrameSize(NSSize(width: frame.width, height: height)) }
		relayout()
	}
	
	override func mouseUp(with event: NSEvent) {
		guard resizing else { return }
		resizing = false
		let height = boxHeight
		previewHeight = nil
		item.height = min(max(Int((height / max(embedWidth, 1) * 100).rounded()), 10), 150)
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
		let duration = 0.28
		animation = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self] timer in
			guard let self else { timer.invalidate(); return }
			let t = min(1, Date().timeIntervalSince(began) / duration)
			let eased = 1 - pow(1 - t, 3)
			self.scrollX = start + (end - start) * CGFloat(eased)
			self.relayout()
			if t >= 1 { timer.invalidate() }
		}
	}
	
	/// Scrolls so that the selected image is fully visible
	func scrollToSelected() {
		let frames = stripFrames
		guard selectedIndex < frames.count else { return }
		let frame = frames[selectedIndex]
		if frame.minX - ViralCarouselView.padding < scrollX {
			animateScroll(to: frame.minX - ViralCarouselView.padding)
		} else if frame.maxX + ViralCarouselView.padding > scrollX + embedWidth {
			animateScroll(to: frame.maxX + ViralCarouselView.padding - embedWidth)
		}
	}
	
	@objc func showPrevious(_ sender: Any?) {
		// Bring the image cut off on the left fully into view (or scroll a full width)
		let frames = stripFrames
		if let i = frames.lastIndex(where: { $0.minX < scrollX - 1 }) {
			var target = max(frames[i].maxX + ViralCarouselView.padding - embedWidth, scrollX - embedWidth * 0.8)
			if target >= scrollX - 1 { target = scrollX - embedWidth * 0.8 }
			animateScroll(to: target)
			selectedIndex = i
		} else {
			animateScroll(to: 0)
		}
		needsDisplay = true
	}
	
	@objc func showNext(_ sender: Any?) {
		// Bring the image cut off on the right fully into view (or scroll a full width)
		let frames = stripFrames
		let right = scrollX + embedWidth
		if let i = frames.firstIndex(where: { $0.maxX > right + 1 }) {
			var target = min(frames[i].minX - ViralCarouselView.padding, scrollX + embedWidth * 0.8)
			if target <= scrollX + 1 { target = scrollX + embedWidth * 0.8 }
			animateScroll(to: target)
			selectedIndex = i
		} else {
			animateScroll(to: maxScroll)
		}
		needsDisplay = true
	}
	
	override func addImages(_ images: [NSImage]) {
		let lines = newImageLines(images)
		guard !lines.isEmpty else { return }
		let ids = lines.compactMap { $0.ids.first }
		let at = item.ids.isEmpty ? 0 : min(selectedIndex + 1, item.ids.count)
		item.ids.insert(contentsOf: ids, at: at)
		selectedIndex = at + ids.count - 1
		relayout()
		write([item.text])
		scrollToSelected()
	}
	
	func removeSelected() {
		guard selectedIndex < item.ids.count else {
			host?.deleteEmbed(self)
			return
		}
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
	
	override func keyDown(with event: NSEvent) {
		switch event.keyCode {
		case 123:
			if selectedIndex > 0 { selectedIndex -= 1; scrollToSelected(); needsDisplay = true }
		case 124:
			if selectedIndex < item.ids.count - 1 { selectedIndex += 1; scrollToSelected(); needsDisplay = true }
		case 51, 117: removeSelected()
		default: super.keyDown(with: event)
		}
	}
	
	override func menu(for event: NSEvent) -> NSMenu? {
		window?.makeFirstResponder(self)
		let point = convert(event.locationInWindow, from: nil)
		if let i = stripFrames.firstIndex(where: { $0.offsetBy(dx: -scrollX, dy: 0).contains(point) }) {
			selectedIndex = i
			needsDisplay = true
		}
		
		let menu = NSMenu()
		let add = NSMenuItem(title: "Add Images…", action: #selector(chooseAndAddImages(_:)), keyEquivalent: "")
		add.target = self
		menu.addItem(add)
		if !item.ids.isEmpty {
			let remove = NSMenuItem(title: "Remove This Image", action: #selector(removeImageFromMenu(_:)), keyEquivalent: "")
			remove.target = self
			menu.addItem(remove)
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
	
	/// Finds image groups and carousels from the text
	fileprivate func embedBlocks() -> [EmbedBlock] {
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
					if embed.kind == .image, var block = current, block.kind == .image {
						block.lines.append(line)
						block.range.length = NSMaxRange(content) - block.range.location
						current = block
					} else {
						if let block = current { blocks.append(block) }
						current = EmbedBlock(range: content, lines: [line], kind: embed.kind)
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
		if first.kind == .carousel { return ViralCarouselView.height(for: first, width: tableWidth) }
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
			let widthChanged = view.embedWidth != width
			view.embedWidth = width
			
			let text = ns.substring(with: block.range)
			if text != view.sourceText || widthChanged {
				view.load(text: text, lines: block.lines)
			}
			
			let glyph = lm.glyphIndexForCharacter(at: block.range.location)
			let lineRect = lm.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
			let origin = textContainerOrigin
			let frame = NSRect(x: origin.x + tc.lineFragmentPadding, y: origin.y + lineRect.minY,
							   width: width + 24, height: view.totalHeight)
			if view.frame != frame { view.frame = frame }
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
		window?.makeFirstResponder(self)
		textActions.replace(range, with: "")
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
		} else if EmbedLine.parse(current)?.kind == .image && lines.allSatisfy({ EmbedLine.parse($0)?.kind == .image }) {
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
		if let embed = window?.firstResponder as? ViralEmbedView, embed.host === self {
			let images = viralImages(from: pasteboard)
			if images.isEmpty { return false }
			embed.addImages(images)
			return true
		}
		let images = viralImages(from: pasteboard)
		guard !images.isEmpty else { return false }
		insertImages(images)
		return true
	}
	
	/// Called from `performDragOperation:`. Returns `true` if images were dropped.
	@objc func dropImagesIfNeeded(_ sender: NSDraggingInfo) -> Bool {
		let images = viralImages(from: sender.draggingPasteboard)
		guard !images.isEmpty else { return false }
		
		let point = convert(sender.draggingLocation, from: nil)
		if let view = embedViews.first(where: { $0.frame.contains(point) }) {
			view.addImages(images)
			return true
		}
		
		let index = characterIndexForInsertion(at: point)
		window?.makeFirstResponder(self)
		setSelectedRange(NSRange(location: min(index, (self.string as NSString).length), length: 0))
		insertImages(images)
		return true
	}
	
	@objc func viralInsertImage(_ sender: Any?) {
		chooseImages { [weak self] images in self?.insertImages(images) }
	}
	
	@objc func viralInsertCarousel(_ sender: Any?) {
		insertCarousel()
	}
}
