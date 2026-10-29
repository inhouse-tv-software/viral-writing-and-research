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
 
 Notion-style tables. Tables are stored as Markdown pipe tables, one row per line:
 
 | Item  | Price |
 |-------|-------|
 | Soya  | 120   |
 
 The layout manager hides the pipes and draws a grid. Here we handle editing:
 columns are re-aligned while typing, Tab / Shift-Tab moves between cells,
 Return adds a row (or exits the table on an empty last row), and `/table` + Return inserts a new table.
 
 */

fileprivate let BeatTableMenuItemTag = 947_100

fileprivate struct BeatTable {
	/// Ranges of each table line (without line break)
	var ranges: [NSRange]
	/// Row index for each line, `-1` for the header separator
	var lineRows: [Int]
	/// Cell contents (separator not included)
	var rows: [[String]]
	var header: Bool
	
	var fullRange: NSRange {
		guard let first = ranges.first, let last = ranges.last else { return NSRange(location: 0, length: 0) }
		return NSRange(location: first.location, length: NSMaxRange(last) - first.location)
	}
	var columnCount: Int { return rows.first?.count ?? 1 }
	func emptyRow() -> [String] { return Array(repeating: "", count: columnCount) }
}

fileprivate struct BeatTableCell {
	var row: Int
	var col: Int
	var offset: Int
}

fileprivate func btIsTableRow(_ s: String) -> Bool {
	let t = s.trimmingCharacters(in: .whitespaces)
	return t.count >= 2 && t.hasPrefix("|") && t.hasSuffix("|")
}

fileprivate func btIsSeparator(_ s: String) -> Bool {
	guard btIsTableRow(s), s.contains("-") else { return false }
	return s.allSatisfy { $0 == "|" || $0 == "-" || $0 == ":" || $0 == " " }
}

fileprivate func btCells(_ s: String) -> [String] {
	var t = s.trimmingCharacters(in: .whitespaces)
	if t.hasPrefix("|") { t.removeFirst() }
	if t.hasSuffix("|") { t.removeLast() }
	return t.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
}

fileprivate func btLength(_ s: String) -> Int { return (s as NSString).length }

fileprivate func btWidths(_ rows: [[String]]) -> [Int] {
	let cols = rows.first?.count ?? 1
	var widths = Array(repeating: 3, count: cols)
	for r in rows {
		for (i, c) in r.enumerated() where i < cols {
			widths[i] = max(widths[i], btLength(c))
		}
	}
	return widths
}

fileprivate func btFormat(_ rows: [[String]], header: Bool) -> [String] {
	let widths = btWidths(rows)
	var out: [String] = []
	for (ri, r) in rows.enumerated() {
		var cells: [String] = []
		for (i, c) in r.enumerated() {
			cells.append(c + String(repeating: " ", count: max(0, widths[i] - btLength(c))))
		}
		out.append("| " + cells.joined(separator: " | ") + " |")
		if ri == 0 && header {
			out.append("|" + widths.map { String(repeating: "-", count: $0 + 2) }.joined(separator: "|") + "|")
		}
	}
	return out
}

/// Line index of given row in formatted output
fileprivate func btFormattedLineIndex(row: Int, header: Bool) -> Int {
	return (header && row > 0) ? row + 1 : row
}

/// Local offset for a cell position in formatted output
fileprivate func btFormattedOffset(_ rows: [[String]], header: Bool, cell: BeatTableCell) -> Int {
	let lines = btFormat(rows, header: header)
	let widths = btWidths(rows)
	let row = min(max(cell.row, 0), rows.count - 1)
	let col = min(max(cell.col, 0), widths.count - 1)
	let lineIndex = btFormattedLineIndex(row: row, header: header)
	
	var offset = 0
	for i in 0..<lineIndex { offset += btLength(lines[i]) + 1 }
	offset += 2
	for k in 0..<col { offset += widths[k] + 3 }
	offset += min(max(cell.offset, 0), btLength(rows[row][col]))
	return offset
}

fileprivate func btLineRange(_ ns: NSString, _ location: Int) -> NSRange {
	let loc = min(max(location, 0), ns.length)
	var r = ns.lineRange(for: NSRange(location: loc, length: 0))
	if r.length > 0 && ns.character(at: NSMaxRange(r) - 1) == 10 { r.length -= 1 }
	return r
}

public extension BeatTextView {
	
	// MARK: Finding and reading tables
	
	fileprivate func tableAt(_ location: Int) -> BeatTable? {
		let ns = self.string as NSString
		let current = btLineRange(ns, location)
		guard btIsTableRow(ns.substring(with: current)) else { return nil }
		
		var ranges = [current]
		
		var start = current.location
		while start > 0 {
			let prev = btLineRange(ns, start - 1)
			if prev.location >= start || !btIsTableRow(ns.substring(with: prev)) { break }
			ranges.insert(prev, at: 0)
			start = prev.location
		}
		
		var end = NSMaxRange(current)
		while end < ns.length {
			let next = btLineRange(ns, end + 1)
			if next.location <= end || next.length == 0 || !btIsTableRow(ns.substring(with: next)) { break }
			ranges.append(next)
			end = NSMaxRange(next)
		}
		
		var rows: [[String]] = []
		var lineRows: [Int] = []
		var header = false
		
		for r in ranges {
			let s = ns.substring(with: r)
			if btIsSeparator(s) {
				if rows.count == 1 { header = true }
				lineRows.append(-1)
			} else {
				lineRows.append(rows.count)
				rows.append(btCells(s))
			}
		}
		
		if rows.isEmpty { rows = [[""]] }
		let cols = rows.map { $0.count }.max() ?? 1
		rows = rows.map { $0 + Array(repeating: "", count: cols - $0.count) }
		
		return BeatTable(ranges: ranges, lineRows: lineRows, rows: rows, header: header)
	}
	
	fileprivate func currentTable() -> BeatTable? {
		return tableAt(self.selectedRange.location)
	}
	
	/// Returns the cell at given location, along with where the cell content begins and its length in the current text
	fileprivate func cellAt(_ table: BeatTable, location: Int) -> BeatTableCell {
		let ns = self.string as NSString
		
		var lineIndex = table.ranges.count - 1
		for (i, r) in table.ranges.enumerated() where location <= NSMaxRange(r) {
			lineIndex = i
			break
		}
		
		var row = table.lineRows[lineIndex]
		if row < 0 { row = 0 }
		
		let lineRange = table.ranges[lineIndex]
		let line = ns.substring(with: lineRange) as NSString
		let local = location - lineRange.location
		
		var pipes: [Int] = []
		for i in 0..<line.length where line.character(at: i) == 124 { pipes.append(i) }
		
		guard pipes.count > 0, local > pipes[0] else {
			return BeatTableCell(row: row, col: 0, offset: 0)
		}
		
		var col = pipes.filter { $0 < local }.count - 1
		col = min(max(col, 0), table.columnCount - 1)
		
		let (contentStart, contentLength) = contentRange(line: line, pipes: pipes, col: col)
		let offset = min(max(local - contentStart, 0), contentLength)
		
		return BeatTableCell(row: row, col: col, offset: offset)
	}
	
	/// Content start (local) and trimmed length of a cell on a line
	fileprivate func contentRange(line: NSString, pipes: [Int], col: Int) -> (Int, Int) {
		guard col < pipes.count else { return (line.length, 0) }
		let pipe = pipes[col]
		let next = (col + 1 < pipes.count) ? pipes[col + 1] : line.length
		
		var start = pipe + 1
		while start < next && line.character(at: start) == 32 { start += 1 }
		var end = next
		while end > start && line.character(at: end - 1) == 32 { end -= 1 }
		
		return (start, end - start)
	}
	
	/// When typing, the caret should be inside cell content (or one space after it, so you can type words).
	/// Returns a corrected caret position if the caret is in padding or on a separator.
	fileprivate func caretPositionForTyping(_ table: BeatTable, location: Int) -> Int? {
		let ns = self.string as NSString
		guard let lineIndex = table.ranges.firstIndex(where: { NSLocationInRange(location, NSRange(location: $0.location, length: $0.length + 1)) }) else { return nil }
		
		// Don't type on the separator row, jump to the header instead
		if table.lineRows[lineIndex] < 0 {
			return currentPosition(table, cell: BeatTableCell(row: 0, col: 0, offset: Int.max))
		}
		
		let lineRange = table.ranges[lineIndex]
		let line = ns.substring(with: lineRange) as NSString
		let local = location - lineRange.location
		
		var pipes: [Int] = []
		for i in 0..<line.length where line.character(at: i) == 124 { pipes.append(i) }
		guard pipes.count >= 2 else { return nil }
		
		if local <= pipes[0] {
			return currentPosition(table, cell: BeatTableCell(row: table.lineRows[lineIndex], col: 0, offset: 0))
		}
		if local > pipes[pipes.count - 1] {
			return currentPosition(table, cell: BeatTableCell(row: table.lineRows[lineIndex], col: pipes.count - 2, offset: Int.max))
		}
		
		let col = min(max(pipes.filter { $0 < local }.count - 1, 0), pipes.count - 2)
		let (start, length) = contentRange(line: line, pipes: pipes, col: col)
		let nextPipe = pipes[col + 1]
		
		if local < start {
			// Leading space: an empty cell or caret right after the separator
			return lineRange.location + start
		} else if local > start + length + 1 || local >= nextPipe {
			// Somewhere in the padding
			return lineRange.location + start + length
		}
		return nil
	}
	
	/// Global position for a cell in the *current* (possibly unaligned) text
	fileprivate func currentPosition(_ table: BeatTable, cell: BeatTableCell) -> Int? {
		guard let lineIndex = table.lineRows.firstIndex(of: cell.row) else { return nil }
		let ns = self.string as NSString
		let lineRange = table.ranges[lineIndex]
		let line = ns.substring(with: lineRange) as NSString
		
		var pipes: [Int] = []
		for i in 0..<line.length where line.character(at: i) == 124 { pipes.append(i) }
		guard cell.col < pipes.count - 1 else { return nil }
		
		let (start, length) = contentRange(line: line, pipes: pipes, col: cell.col)
		return lineRange.location + start + min(cell.offset, length)
	}
	
	// MARK: Writing tables
	
	/// Writes the given rows in place of the table and moves the caret to given cell
	fileprivate func apply(_ table: BeatTable, rows: [[String]], header: Bool, cell: BeatTableCell?, suffix: String = "") {
		guard let textActions = self.editorDelegate?.textActions else { return }
		
		let ns = self.string as NSString
		let fullRange = table.fullRange
		let newLines = btFormat(rows, header: header)
		let newText = newLines.joined(separator: "\n")
		
		if ns.substring(with: fullRange) != newText || suffix.count > 0 {
			self.undoManager?.beginUndoGrouping()
			if newLines.count == table.ranges.count && suffix.count == 0 {
				// Replace only the lines that changed, bottom up so earlier ranges stay valid
				for i in (0..<newLines.count).reversed() {
					if ns.substring(with: table.ranges[i]) != newLines[i] {
						textActions.replace(table.ranges[i], with: newLines[i])
					}
				}
			} else {
				textActions.replace(fullRange, with: newText + suffix)
			}
			self.undoManager?.endUndoGrouping()
		}
		
		if let cell {
			let position = fullRange.location + btFormattedOffset(rows, header: header, cell: cell)
			self.selectedRange = NSRange(location: position, length: 0)
		}
	}
	
	fileprivate func realign(_ table: BeatTable) {
		let location = self.selectedRange.location
		let cell = cellAt(table, location: location)
		let formatted = btFormat(table.rows, header: table.header).joined(separator: "\n")
		let ns = self.string as NSString
		if ns.substring(with: table.fullRange) == formatted { return }
		apply(table, rows: table.rows, header: table.header, cell: cell)
	}
	
	fileprivate func deleteTable(_ table: BeatTable) {
		guard let textActions = self.editorDelegate?.textActions else { return }
		let ns = self.string as NSString
		var range = table.fullRange
		if NSMaxRange(range) < ns.length { range.length += 1 }
		textActions.replace(range, with: "")
		self.selectedRange = NSRange(location: min(range.location, (self.string as NSString).length), length: 0)
	}
	
	/// Inserts a new table at the caret. Uses the current line if it's empty.
	fileprivate func insertTable(columns: Int, bodyRows: Int, replacing lineRange: NSRange? = nil) {
		guard let textActions = self.editorDelegate?.textActions else { return }
		let ns = self.string as NSString
		
		let cols = min(max(columns, 1), 12)
		let body = min(max(bodyRows, 1), 50)
		var rows: [[String]] = []
		for _ in 0..<(body + 1) { rows.append(Array(repeating: "", count: cols)) }
		let text = btFormat(rows, header: true).joined(separator: "\n")
		
		var location: Int
		if let lineRange {
			textActions.replace(lineRange, with: text)
			location = lineRange.location
		} else {
			let current = btLineRange(ns, self.selectedRange.location)
			if current.length == 0 {
				textActions.replace(current, with: text)
				location = current.location
			} else {
				textActions.replace(NSRange(location: NSMaxRange(current), length: 0), with: "\n\n" + text)
				location = NSMaxRange(current) + 2
			}
		}
		
		self.selectedRange = NSRange(location: location + 2, length: 0)
	}
	
	// MARK: Key handling
	
	/// Called from `keyDown:` before default handling. Returns `true` if the event was handled.
	@objc func handleTableKeyDown(_ event: NSEvent) -> Bool {
		if self.hasMarkedText() { return false }
		
		var flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
		flags.remove(.capsLock)
		flags.remove(.numericPad)
		flags.remove(.function)
		
		let selection = self.selectedRange
		
		switch event.keyCode {
		case 36, 76:
			// Return
			guard flags.isEmpty, selection.length == 0 else { return false }
			if insertTableFromCommand() { return true }
			guard let table = currentTable() else { return false }
			tableReturn(table)
			return true
			
		case 48:
			// Tab / Shift-Tab
			guard flags.isEmpty || flags == .shift, let table = currentTable() else { return false }
			tableTab(table, backwards: flags == .shift)
			return true
			
		case 51:
			// Backspace
			guard flags.isEmpty, selection.length == 0, let table = currentTable() else { return false }
			return tableBackspace(table)
			
		default:
			guard selection.length == 0,
				  flags.subtracting(.shift).isEmpty,
				  let chars = event.characters, chars.count > 0,
				  let table = currentTable()
			else { return false }
			
			// Ignore arrow keys, function keys and control characters
			if let scalar = chars.unicodeScalars.first, scalar.value >= 0xF700 || scalar.value < 32 || scalar.value == 127 { return false }
			
			// Typing a pipe would break the columns
			if chars.contains("|") { return true }
			
			// Move the caret out of padding / separators into the cell content
			if let position = caretPositionForTyping(table, location: selection.location), position != selection.location {
				self.selectedRange = NSRange(location: position, length: 0)
			}
			return false
		}
	}
	
	/// Called from `keyDown:` after default handling. Re-aligns the table if needed.
	@objc func tableDidProcessKeyDown(_ event: NSEvent) {
		if self.hasMarkedText() { return }
		guard self.selectedRange.length == 0, let table = currentTable() else { return }
		// Don't re-align right after a word + space, so words can be typed (trailing spaces get trimmed)
		let ns = self.string as NSString
		let caret = self.selectedRange.location
		if caret >= 2 && ns.character(at: caret - 1) == 32 {
			let before = ns.character(at: caret - 2)
			if before != 32 && before != 124 { return }
		}
		realign(table)
	}
	
	fileprivate func insertTableFromCommand() -> Bool {
		let ns = self.string as NSString
		let lineRange = btLineRange(ns, self.selectedRange.location)
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
	
	fileprivate func tableReturn(_ table: BeatTable) {
		let cell = cellAt(table, location: self.selectedRange.location)
		var rows = table.rows
		
		// Empty row with only empty rows below it: exit the table
		let restIsEmpty = rows[cell.row...].allSatisfy { row in row.allSatisfy { $0.isEmpty } }
		let isHeader = table.header && cell.row == 0
		
		if restIsEmpty && cell.row > 0 && !isHeader {
			// Exit the table
			rows.removeSubrange(cell.row..<rows.count)
			let ns = self.string as NSString
			let end = NSMaxRange(table.fullRange)
			let rest = ns.substring(from: end)
			let suffix = rest.hasPrefix("\n") || rest.isEmpty ? "\n\n" : "\n\n\n"
			
			let newText = btFormat(rows, header: table.header).joined(separator: "\n")
			apply(table, rows: rows, header: table.header, cell: nil, suffix: suffix)
			self.selectedRange = NSRange(location: table.fullRange.location + btLength(newText) + 2, length: 0)
			return
		}
		
		rows.insert(table.emptyRow(), at: cell.row + 1)
		apply(table, rows: rows, header: table.header, cell: BeatTableCell(row: cell.row + 1, col: 0, offset: 0))
	}
	
	fileprivate func tableTab(_ table: BeatTable, backwards: Bool) {
		let cell = cellAt(table, location: self.selectedRange.location)
		var rows = table.rows
		var row = cell.row
		var col = cell.col + (backwards ? -1 : 1)
		
		if col >= table.columnCount { col = 0; row += 1 }
		if col < 0 { col = table.columnCount - 1; row -= 1 }
		if row < 0 { row = 0; col = 0 }
		if row >= rows.count { rows.append(table.emptyRow()) }
		
		apply(table, rows: rows, header: table.header, cell: BeatTableCell(row: row, col: col, offset: Int.max))
	}
	
	fileprivate func tableBackspace(_ table: BeatTable) -> Bool {
		let cell = cellAt(table, location: self.selectedRange.location)
		guard cell.offset == 0 else { return false }
		
		var rows = table.rows
		let emptyRow = rows[cell.row].allSatisfy { $0.isEmpty }
		
		if emptyRow && cell.col == 0 && rows.count > 1 {
			// Remove an empty row and move to the end of the previous one
			rows.remove(at: cell.row)
			let target = max(cell.row - 1, 0)
			apply(table, rows: rows, header: table.header && rows.count > 0, cell: BeatTableCell(row: target, col: table.columnCount - 1, offset: Int.max))
		} else if cell.col > 0 {
			// Don't delete the column separator, just move to the previous cell
			apply(table, rows: rows, header: table.header, cell: BeatTableCell(row: cell.row, col: cell.col - 1, offset: Int.max))
		}
		
		return true
	}
	
	// MARK: Context menu
	
	@objc func addTableMenuItems(_ menu: NSMenu) {
		for item in menu.items where item.tag == BeatTableMenuItemTag {
			menu.removeItem(item)
		}
		
		var items: [NSMenuItem] = []
		
		if currentTable() != nil {
			items.append(NSMenuItem(title: "Add Row Below", action: #selector(tableAddRow(_:)), keyEquivalent: ""))
			items.append(NSMenuItem(title: "Add Column Right", action: #selector(tableAddColumn(_:)), keyEquivalent: ""))
			items.append(NSMenuItem(title: "Delete Row", action: #selector(tableDeleteRow(_:)), keyEquivalent: ""))
			items.append(NSMenuItem(title: "Delete Column", action: #selector(tableDeleteColumn(_:)), keyEquivalent: ""))
			items.append(NSMenuItem(title: "Delete Table", action: #selector(tableDelete(_:)), keyEquivalent: ""))
		} else {
			items.append(NSMenuItem(title: "Insert Table", action: #selector(tableInsert(_:)), keyEquivalent: ""))
		}
		
		let separator = NSMenuItem.separator()
		items.append(separator)
		
		for (i, item) in items.enumerated() {
			item.tag = BeatTableMenuItemTag
			item.target = self
			menu.insertItem(item, at: i)
		}
	}
	
	@objc func tableInsert(_ sender: Any?) {
		insertTable(columns: 3, bodyRows: 2)
	}
	
	@objc func tableAddRow(_ sender: Any?) {
		guard let table = currentTable() else { return }
		let cell = cellAt(table, location: self.selectedRange.location)
		var rows = table.rows
		rows.insert(table.emptyRow(), at: cell.row + 1)
		apply(table, rows: rows, header: table.header, cell: BeatTableCell(row: cell.row + 1, col: 0, offset: 0))
	}
	
	@objc func tableAddColumn(_ sender: Any?) {
		guard let table = currentTable() else { return }
		let cell = cellAt(table, location: self.selectedRange.location)
		let rows = table.rows.map { row -> [String] in
			var r = row
			r.insert("", at: min(cell.col + 1, r.count))
			return r
		}
		apply(table, rows: rows, header: table.header, cell: BeatTableCell(row: cell.row, col: cell.col + 1, offset: 0))
	}
	
	@objc func tableDeleteRow(_ sender: Any?) {
		guard let table = currentTable() else { return }
		let cell = cellAt(table, location: self.selectedRange.location)
		if table.rows.count <= 1 { deleteTable(table); return }
		var rows = table.rows
		rows.remove(at: cell.row)
		apply(table, rows: rows, header: table.header, cell: BeatTableCell(row: min(cell.row, rows.count - 1), col: 0, offset: 0))
	}
	
	@objc func tableDeleteColumn(_ sender: Any?) {
		guard let table = currentTable() else { return }
		let cell = cellAt(table, location: self.selectedRange.location)
		if table.columnCount <= 1 { deleteTable(table); return }
		let rows = table.rows.map { row -> [String] in
			var r = row
			if cell.col < r.count { r.remove(at: cell.col) }
			return r
		}
		apply(table, rows: rows, header: table.header, cell: BeatTableCell(row: cell.row, col: max(cell.col - 1, 0), offset: 0))
	}
	
	@objc func tableDelete(_ sender: Any?) {
		guard let table = currentTable() else { return }
		deleteTable(table)
	}
}
