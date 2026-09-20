import 'dart:collection';

import 'package:flutter/foundation.dart';
import 'package:html/dom.dart';
import 'package:html/parser.dart';

abstract class CompressedNode {
	Node reconstruct();
	bool get remapDescendants;
}

class LiteralNode implements CompressedNode {
	final Node node;
	LiteralNode(this.node);
	@override
	Node reconstruct() => node;
	@override
	bool get remapDescendants => false;
	@override
	bool operator == (Object other) =>
		identical(this, other) ||
		(other is LiteralNode) &&
		(other.node == node);
	@override
	int get hashCode => node.hashCode;
	@override
	String toString() => 'LiteralNode(node: $node)';
}

class CompressedTag implements CompressedNode {
	final String localName;
	final LinkedHashMap<Object, String> attributes;
	const CompressedTag(this.localName, this.attributes);
	@override
	Node reconstruct() => Element.tag(localName)..attributes = attributes;
	@override
	bool get remapDescendants => true;
	@override
	bool operator == (Object other) =>
		identical(this, other) ||
		(other is CompressedTag) &&
		(other.localName == localName) &&
		mapEquals(other.attributes, attributes);
	@override
	int get hashCode => Object.hash(localName, Object.hashAll(attributes.values));
	@override
	String toString() => 'CompressedTag(<$localName${attributes.isNotEmpty ? ' ' : ''}${attributes.entries.map((a) => '${a.key}="${a.value}"').join(' ')}>)';
}

class CompressedHTML {
	final String html;
	final Map<String, CompressedNode> codex;
	final bool isCompletelyCompressed;

	const CompressedHTML({
		required this.html,
		required this.codex,
		required this.isCompletelyCompressed
	});

	void _remap(List<Element> elements) {
		for (final child in elements) {
			if (child.localName == 'br') {
				continue;
			}
			final replacement = codex[child.localName];
			if (replacement == null) {
				throw FormatException('Unexpected translated HTML tag', child.localName);
			}
			final newChild = replacement.reconstruct();
			child.reparentChildren(newChild);
			child.replaceWith(newChild);
			if (replacement.remapDescendants) {
				_remap(newChild.children);
			}
		}
	}

	String decompressTranslation(String translation) {
		final body = parseFragment(translation.replaceAll('<br></br>', '<br>'));
		_remap(body.children);
		return body.outerHtml;
	}
}

final _compressiblePatterns = [
	RegExp(r'^https?:\/\/[^ ]+$'), // url
	RegExp(r'^[0-9>]+$') // entirely non-alphabetic
];

const _tagBlacklist = {
	'a', 'b', 'br', 'dd', 'dl', 'dt', 'em', 'h1', 'hr', 'i', 'li', 'ol', 'p', 'q', 'rp', 'rt', 's', 'td', 'th', 'tr', 'tt', 'u', 'ul'
};

CompressedHTML compressHTML(String html) {
	final body = parseFragment(html);
	final reverseCodex = <CompressedNode, String>{};
	String currentShortform = 'c';
	String incrementString(String s) {
		// Letters only, counting a, b, ... z, aa, ab, ... az, ba, ... and never
		// reaching a digit. That matters because a compressed tag is what carries
		// a link or a quote - an empty element where the URL used to be - through
		// a translation, and the engines that do the translating shield tags they
		// recognise as tags. Ours recognises alphabetic names; a name like a0 is
		// not one, so the link inside it can be lost with nothing left to put
		// back.
		final codes = s.codeUnits.toList();
		for (var i = codes.length - 1; i >= 0; i--) {
			if (codes[i] < 0x7A) {
				codes[i]++;
				return String.fromCharCodes(codes);
			}
			codes[i] = 0x61;
		}
		return 'a${String.fromCharCodes(codes)}';
	}
	String getNextShortform() {
		final ret = currentShortform;
		do {
			currentShortform = incrementString(currentShortform);
		} while (_tagBlacklist.contains(currentShortform));
		return ret;
	}
	final Set<Node> compressibleCache = {};
	bool firstPass(List<Node> nodes) {
		bool allCompressible = true;
		for (final node in nodes) {
			final compressible = switch (node) {
				Element e => firstPass(e.nodes),
				Text(data: final text) => _compressiblePatterns.any((r) => r.hasMatch(text)),
				_ => false // Unknown node type
			};
			if (compressible) {
				compressibleCache.add(node);
			}
			else {
				allCompressible = false;
			}
		}
		return allCompressible;
	}
	void secondPass(List<Node> nodes) {
		for (final node in nodes) {
			if (node case Element(localName: 'br')) {
				// <br> is already optimally short
			}
			else if (compressibleCache.contains(node)) {
				final key = LiteralNode(node);
				final shortform = reverseCodex.putIfAbsent(key, getNextShortform);
				final newChild = Element.tag(shortform);
				node.replaceWith(newChild);
			}
			else if (node case Element child) {
				final key = CompressedTag(child.localName!, child.attributes);
				final shortform = reverseCodex.putIfAbsent(key, getNextShortform);
				final newChild = Element.tag(shortform);
				child.reparentChildren(newChild);
				child.replaceWith(newChild);
				secondPass(newChild.nodes);
			}
		}
	}
	final isCompletelyCompressed = firstPass(body.nodes);
	secondPass(body.nodes);
	return CompressedHTML(
		html: body.outerHtml.replaceAll('<br>', '<br></br>'),
		codex: {
			for (final entry in reverseCodex.entries) entry.value: entry.key
		},
		isCompletelyCompressed : isCompletelyCompressed
	);
}