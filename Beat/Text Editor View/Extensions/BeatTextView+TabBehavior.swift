//
//  BeatTextView+TabBehavior.swift
//  Beat macOS
//
//  Created by Lauri-Matti Parppei on 27.10.2025.
//  Copyright © 2025 Lauri-Matti Parppei. All rights reserved.
//

import Foundation
import AppKit

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
		
		// Keep the main caret where it was (outside the table)
		if selection.location > range.location {
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
		guard window?.firstResponder === self else { return }
		let selection = self.selectedRange()
		guard selection.length == 0 else { return }
		
		for view in tableViews {
			let range = view.tableRange
			if selection.location >= range.location && selection.location <= NSMaxRange(range) && range.length > 0 {
				btLog("CARET INTO TABLE at \(selection.location)")
				let row = selection.location == range.location ? 0 : view.model.rows.count - 1
				DispatchQueue.main.async { view.focus(row: row, col: 0, atEnd: true) }
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
		let separator = NSMenuItem.separator()
		separator.tag = BeatTableMenuItemTag
		menu.insertItem(separator, at: 1)
	}
	
	@objc func tableInsert(_ sender: Any?) {
		insertTable(columns: 3, bodyRows: 2)
	}
}
