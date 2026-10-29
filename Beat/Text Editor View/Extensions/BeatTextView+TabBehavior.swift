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
 
 Tables never get wider than the page. When a cell doesn't fit, its text wraps onto
 more lines, and rows are then separated with `|:---|` lines so we know which lines belong together:
 
 | Item  | Notes                |
 |-------|----------------------|
 | Soya  | A very long note     |
 |       | that wraps           |
 |:------|:---------------------|
 | Tofu  | Short                |
 |:------|:---------------------|
 
 The layout manager hides the pipes and draws a grid. Here we handle editing:
 columns are re-aligned while typing, Tab / Shift-Tab moves between cells,
 Return adds a row (or exits the table on an empty last row), and `/table` + Return inserts a new table.
 
 */

fileprivate let BeatTableMenuItemTag = 947_100
/// Max characters per table line. Printed action lines are 60 characters wide in Courier 12pt.
fileprivate let BeatTableMaxPrintWidth = 60
/// Columns won't shrink below this when fitting a table to the page
fileprivate let BeatTableMinColumnWidth = 6

fileprivate struct BeatTable {
	/// Ranges of each table line (without line break)
	var ranges: [NSRange]
	/// Logical row index for each line, `-1` for separators
	var lineRows: [Int]
	/// Line indices for each logical row
	var groups: [[Int]]
	/// Cell contents for each logical row
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
	/// Offset inside the (unwrapped) cell content
	var offset: Int
	/// `true` when the caret is at the very start of a wrapped line of this cell
	var atLineStart: Bool = false
}

/// Wrapped cell content: fragments and where each one starts in the content
fileprivate struct BTWrapped {
	var fragments: [String]
	var starts: [Int]
	var length: Int { return (starts.last ?? 0) + btLength(fragments.last ?? "") }
}

fileprivate struct BTLayout {
	var lines: [String]
	var widths: [Int]
	var rowStartLine: [Int]
	var wrapped: [[BTWrapped]]
}

fileprivate func btLength(_ s: String) -> Int { return (s as NSString).length }

fileprivate func btIsTableRow(_ s: String) -> Bool {
	let t = s.trimmingCharacters(in: .whitespaces)
	return t.count >= 2 && t.hasPrefix("|") && t.hasSuffix("|")
}

fileprivate func btIsSeparator(_ s: String) -> Bool {
	guard btIsTableRow(s), s.contains("-") else { return false }
	return s.allSatisfy { $0 == "|" || $0 == "-" || $0 == ":" || $0 == " " }
}

/// Collapses runs of spaces
fileprivate func btNormalize(_ s: String) -> String {
	return s.components(separatedBy: " ").filter { !$0.isEmpty }.joined(separator: " ")
}

fileprivate func btCells(_ s: String) -> [String] {
	var t = s.trimmingCharacters(in: .whitespaces)
	if t.hasPrefix("|") { t.removeFirst() }
	if t.hasSuffix("|") { t.removeLast() }
	return t.components(separatedBy: "|").map { btNormalize($0.trimmingCharacters(in: .whitespaces)) }
}

fileprivate func btWrap(_ content: String, _ width: Int) -> BTWrapped {
	if btLength(content) <= width { return BTWrapped(fragments: [content], starts: [0]) }
	
	var fragments: [String] = []
	var starts: [Int] = []
	var current = ""
	var currentStart = 0
	var position = 0
	
	for w in content.components(separatedBy: " ") {
		var word = w as NSString
		var wordStart = position
		position += word.length + 1
		if word.length == 0 { continue }
		
		// Break words that are longer than the column
		while word.length > width {
			if current.count > 0 { fragments.append(current); starts.append(currentStart); current = "" }
			fragments.append(word.substring(to: width))
			starts.append(wordStart)
			word = word.substring(from: width) as NSString
			wordStart += width
		}
		
		if current.isEmpty {
			current = word as String
			currentStart = wordStart
		} else if btLength(current) + 1 + word.length <= width {
			current += " " + (word as String)
		} else {
			fragments.append(current); starts.append(currentStart)
			current = word as String
			currentStart = wordStart
		}
	}
	
	if current.count > 0 || fragments.isEmpty { fragments.append(current); starts.append(currentStart) }
	return BTWrapped(fragments: fragments, starts: starts)
}

fileprivate func btLayout(_ rows: [[String]], header: Bool, maxWidth: Int) -> BTLayout {
	let cols = rows.first?.count ?? 1
	var widths = Array(repeating: 3, count: cols)
	for r in rows {
		for (i, c) in r.enumerated() where i < cols { widths[i] = max(widths[i], btLength(c)) }
	}
	
	// Fit to page by shrinking the widest column
	func total(_ w: [Int]) -> Int { return w.reduce(0, +) + 3 * w.count + 1 }
	while total(widths) > maxWidth {
		guard let wi = widths.indices.max(by: { widths[$0] < widths[$1] }), widths[wi] > BeatTableMinColumnWidth else { break }
		widths[wi] -= 1
	}
	
	let wrapped = rows.map { r in r.enumerated().map { btWrap($0.element, widths[$0.offset]) } }
	let multiline = wrapped.contains { row in row.contains { $0.fragments.count > 1 } }
	
	var lines: [String] = []
	var rowStartLine: [Int] = []
	
	for (ri, r) in wrapped.enumerated() {
		rowStartLine.append(lines.count)
		let height = r.map { $0.fragments.count }.max() ?? 1
		for k in 0..<height {
			var cells: [String] = []
			for (i, c) in r.enumerated() {
				let f = k < c.fragments.count ? c.fragments[k] : ""
				cells.append(f + String(repeating: " ", count: max(0, widths[i] - btLength(f))))
			}
			lines.append("| " + cells.joined(separator: " | ") + " |")
		}
		if ri == 0 && header {
			lines.append("|" + widths.map { String(repeating: "-", count: $0 + 2) }.joined(separator: "|") + "|")
		} else if multiline {
			// Rows with wrapped cells are separated by rule lines (also after the last row, so the table reads back correctly)
			lines.append("|" + widths.map { ":" + String(repeating: "-", count: $0 + 1) }.joined(separator: "|") + "|")
		}
	}
	
	return BTLayout(lines: lines, widths: widths, rowStartLine: rowStartLine, wrapped: wrapped)
}

/// Local offset for a cell position in laid out table
fileprivate func btOffset(_ layout: BTLayout, cell: BeatTableCell) -> Int {
	let row = min(max(cell.row, 0), layout.wrapped.count - 1)
	let col = min(max(cell.col, 0), layout.widths.count - 1)
	let w = layout.wrapped[row][col]
	let offset = min(max(cell.offset, 0), w.length)
	
	var k = 0
	for (i, start) in w.starts.enumerated() where start <= offset { k = i }
	
	let lineIndex = layout.rowStartLine[row] + k
	var position = 0
	for i in 0..<lineIndex { position += btLength(layout.lines[i]) + 1 }
	position += 2
	for c in 0..<col { position += layout.widths[c] + 3 }
	position += min(offset - w.starts[k], btLength(w.fragments[k]))
	return position
}

fileprivate func btLineRange(_ ns: NSString, _ location: Int) -> NSRange {
	let loc = min(max(location, 0), ns.length)
	var r = ns.lineRange(for: NSRange(location: loc, length: 0))
	if r.length > 0 && ns.character(at: NSMaxRange(r) - 1) == 10 { r.length -= 1 }
	return r
}

fileprivate func btPipes(_ line: NSString) -> [Int] {
	var pipes: [Int] = []
	for i in 0..<line.length where line.character(at: i) == 124 { pipes.append(i) }
	return pipes
}

/// Content start (local) and trimmed length of a cell on a line
fileprivate func btContentRange(_ line: NSString, pipes: [Int], col: Int) -> (Int, Int) {
	guard col < pipes.count else { return (line.length, 0) }
	let pipe = pipes[col]
	let next = (col + 1 < pipes.count) ? pipes[col + 1] : line.length
	
	var start = pipe + 1
	while start < next && line.character(at: start) == 32 { start += 1 }
	var end = next
	while end > start && line.character(at: end - 1) == 32 { end -= 1 }
	
	return (start, end - start)
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
		
		let strings = ranges.map { ns.substring(with: $0) }
		
		// Find the header separator. It's the first separator, if it doesn't contain ':' or is right after the first line.
		var headerIndex: Int? = nil
		if let first = strings.firstIndex(where: { btIsSeparator($0) }), first > 0 {
			if !strings[first].contains(":") || first == 1 { headerIndex = first }
		}
		let multiline = strings.enumerated().contains { btIsSeparator($0.element) && $0.offset != headerIndex }
		
		var groups: [[Int]] = []
		var lineRows: [Int] = []
		var currentGroup: [Int] = []
		
		for (i, s) in strings.enumerated() {
			if btIsSeparator(s) {
				if currentGroup.count > 0 { groups.append(currentGroup); currentGroup = [] }
				lineRows.append(-1)
			} else if multiline {
				lineRows.append(groups.count)
				currentGroup.append(i)
			} else {
				lineRows.append(groups.count)
				groups.append([i])
			}
		}
		if currentGroup.count > 0 { groups.append(currentGroup) }
		
		var cols = 1
		for s in strings where !btIsSeparator(s) { cols = max(cols, btCells(s).count) }
		
		var rows: [[String]] = []
		for group in groups {
			var row: [String] = []
			for c in 0..<cols {
				let parts = group.map { li -> String in
					let cells = btCells(strings[li])
					return c < cells.count ? cells[c] : ""
				}.filter { !$0.isEmpty }
				row.append(parts.joined(separator: " "))
			}
			rows.append(row)
		}
		if rows.isEmpty { rows = [Array(repeating: "", count: cols)]; groups = [[0]] }
		
		return BeatTable(ranges: ranges, lineRows: lineRows, groups: groups, rows: rows, header: headerIndex != nil)
	}
	
	fileprivate func currentTable() -> BeatTable? {
		return tableAt(self.selectedRange.location)
	}
	
	fileprivate func lineIndex(_ table: BeatTable, location: Int) -> Int {
		for (i, r) in table.ranges.enumerated() where location <= NSMaxRange(r) { return i }
		return table.ranges.count - 1
	}
	
	/// Returns the cell (and offset in its unwrapped content) at given location
	fileprivate func cellAt(_ table: BeatTable, location: Int) -> BeatTableCell {
		let ns = self.string as NSString
		let li = lineIndex(table, location: location)
		
		var row = table.lineRows[li]
		if row < 0 {
			// Separator: use the row above
			row = table.lineRows[..<li].last(where: { $0 >= 0 }) ?? 0
			return BeatTableCell(row: row, col: 0, offset: Int.max)
		}
		
		let lineRange = table.ranges[li]
		let line = ns.substring(with: lineRange) as NSString
		let local = location - lineRange.location
		let pipes = btPipes(line)
		
		var col = 0
		var localOffset = 0
		var contentLength = 0
		
		if pipes.count > 0 && local > pipes[0] {
			col = min(max(pipes.filter { $0 < local }.count - 1, 0), table.columnCount - 1)
			let (contentStart, length) = btContentRange(line, pipes: pipes, col: col)
			contentLength = length
			localOffset = min(max(local - contentStart, 0), length)
		}
		
		// Add the length of wrapped lines above in the same cell
		var base = 0
		for other in table.groups[row] where other < li {
			let cells = btCells(ns.substring(with: table.ranges[other]))
			if col < cells.count, cells[col].count > 0 { base += btLength(cells[col]) + 1 }
		}
		if contentLength == 0 && base > 0 { base -= 1 }
		
		return BeatTableCell(row: row, col: col, offset: base + localOffset, atLineStart: localOffset == 0 && base > 0)
	}
	
	/// Global position in the current line for the start or end of a cell
	fileprivate func positionInLine(_ lineRange: NSRange, col: Int, atEnd: Bool) -> Int? {
		let ns = self.string as NSString
		let line = ns.substring(with: lineRange) as NSString
		let pipes = btPipes(line)
		guard col >= 0, col < pipes.count - 1 else { return nil }
		let (start, length) = btContentRange(line, pipes: pipes, col: col)
		return lineRange.location + start + (atEnd ? length : 0)
	}
	
	/// When typing, the caret should be inside cell content (or one space after it, so you can type words).
	/// Returns a corrected caret position if the caret is in padding or on a separator.
	fileprivate func caretPositionForTyping(_ table: BeatTable, location: Int) -> Int? {
		let ns = self.string as NSString
		let li = lineIndex(table, location: location)
		
		// Don't type on separator rows, jump to the line above instead
		if table.lineRows[li] < 0 {
			guard li > 0 else { return nil }
			return positionInLine(table.ranges[li - 1], col: 0, atEnd: true)
		}
		
		let lineRange = table.ranges[li]
		let line = ns.substring(with: lineRange) as NSString
		let local = location - lineRange.location
		let pipes = btPipes(line)
		guard pipes.count >= 2 else { return nil }
		
		if local <= pipes[0] { return positionInLine(lineRange, col: 0, atEnd: false) }
		if local > pipes[pipes.count - 1] { return positionInLine(lineRange, col: pipes.count - 2, atEnd: true) }
		
		let col = min(max(pipes.filter { $0 < local }.count - 1, 0), pipes.count - 2)
		let (start, length) = btContentRange(line, pipes: pipes, col: col)
		let nextPipe = pipes[col + 1]
		
		if local < start {
			return lineRange.location + start
		} else if local > start + length + 1 || local >= nextPipe {
			return lineRange.location + start + length
		}
		return nil
	}
	
	// MARK: Writing tables
	
	/// Max table width in characters. Uses page width in the editor, capped to the printed width.
	fileprivate func tableMaxWidth() -> Int {
		var maxWidth = BeatTableMaxPrintWidth
		#if os(macOS)
		if let container = self.textContainer, let font = self.font {
			let charWidth = ("0" as NSString).size(withAttributes: [.font: font]).width
			if charWidth > 0 {
				let available = container.size.width - container.lineFragmentPadding * 2
				let chars = Int(floor(available / charWidth)) - 1
				if chars > 20 { maxWidth = min(maxWidth, chars) }
			}
		}
		#endif
		return maxWidth
	}
	
	fileprivate func layout(_ rows: [[String]], header: Bool) -> BTLayout {
		return btLayout(rows, header: header, maxWidth: tableMaxWidth())
	}
	
	/// Writes the given rows in place of the table and moves the caret to given cell
	fileprivate func apply(_ table: BeatTable, rows: [[String]], header: Bool, cell: BeatTableCell?, suffix: String = "") {
		guard let textActions = self.editorDelegate?.textActions else { return }
		
		let ns = self.string as NSString
		let fullRange = table.fullRange
		let tableLayout = layout(rows, header: header)
		let newLines = tableLayout.lines
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
			let position = fullRange.location + btOffset(tableLayout, cell: cell)
			self.selectedRange = NSRange(location: position, length: 0)
		}
		
		redrawTable(NSRange(location: fullRange.location, length: btLength(newText)))
	}
	
	/// The grid depends on neighboring lines, so the whole table needs to be redrawn after edits
	fileprivate func redrawTable(_ range: NSRange) {
		#if os(macOS)
		let length = (self.string as NSString).length
		guard range.location <= length else { return }
		let clamped = NSRange(location: range.location, length: min(range.length + 1, length - range.location))
		self.layoutManager?.invalidateDisplay(forCharacterRange: clamped)
		#endif
	}
	
	fileprivate func realign(_ table: BeatTable) {
		let cell = cellAt(table, location: self.selectedRange.location)
		let formatted = layout(table.rows, header: table.header).lines.joined(separator: "\n")
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
		let text = layout(rows, header: true).lines.joined(separator: "\n")
		
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
			if before != 32 && before != 124 { redrawTable(table.fullRange); return }
		}
		realign(table)
		if let updated = currentTable() { redrawTable(updated.fullRange) }
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
			rows.removeSubrange(cell.row..<rows.count)
			let ns = self.string as NSString
			let rest = ns.substring(from: NSMaxRange(table.fullRange))
			let suffix = rest.hasPrefix("\n") || rest.isEmpty ? "\n\n" : "\n\n\n"
			
			let newText = layout(rows, header: table.header).lines.joined(separator: "\n")
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
		var rows = table.rows
		
		// Start of a wrapped line: delete the character before it in the cell content
		if cell.atLineStart && cell.offset > 0 {
			let content = rows[cell.row][cell.col] as NSString
			let index = min(cell.offset, content.length) - 1
			if index >= 0 {
				rows[cell.row][cell.col] = content.replacingCharacters(in: NSRange(location: index, length: 1), with: "")
				apply(table, rows: rows, header: table.header, cell: BeatTableCell(row: cell.row, col: cell.col, offset: index))
			}
			return true
		}
		
		guard cell.offset == 0 else { return false }
		
		let emptyRow = rows[cell.row].allSatisfy { $0.isEmpty }
		
		if emptyRow && cell.col == 0 && rows.count > 1 {
			// Remove an empty row and move to the end of the previous one
			rows.remove(at: cell.row)
			let target = max(cell.row - 1, 0)
			apply(table, rows: rows, header: table.header, cell: BeatTableCell(row: target, col: table.columnCount - 1, offset: Int.max))
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
		
		items.append(NSMenuItem.separator())
		
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
