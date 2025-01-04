import 'dart:async';
import 'dart:collection';
import 'dart:math';

import 'package:flutter/material.dart';

import 'package:tuple/tuple.dart';

import 'package:fl_nodes/src/core/utils/constants.dart';
import 'package:fl_nodes/src/core/utils/renderbox.dart';

import '../models/node.dart';

import 'node_editor_events.dart';

/// A class that acts as an event bus for the Node Editor.
///
/// This class is responsible for handling and dispatching events
/// related to the node editor. It allows different parts of the
/// application to communicate with each other by sending and
/// receiving events.
///
/// Events can object instances should extend the [NodeEditorEvent] class.
class NodeEditorEventBus {
  final _streamController = StreamController<NodeEditorEvent>.broadcast();
  final Queue<NodeEditorEvent> _eventHistory = Queue();

  void emit(NodeEditorEvent event) {
    _streamController.add(event);

    if (_eventHistory.length >= kMaxEventHistory) {
      _eventHistory.removeFirst();
    }

    _eventHistory.add(event);
  }

  void dispose() {
    _streamController.close();
  }

  Stream<NodeEditorEvent> get events => _streamController.stream;
  NodeEditorEvent get lastEvent => _eventHistory.last;
}

/// A class that defines the behavior of a node editor.
///
/// This class is responsible for handling the interactions and
/// behaviors associated with a node editor, such as node selection,
/// movement, and other editor-specific functionalities.
class NodeEditorBehavior {
  final double zoomSensitivity;
  final double minZoom;
  final double maxZoom;
  final double panSensitivity;
  final double maxPanX;
  final double maxPanY;
  final bool enableKineticScrolling;

  const NodeEditorBehavior({
    this.zoomSensitivity = 0.1,
    this.minZoom = 0.1,
    this.maxZoom = 10.0,
    this.panSensitivity = 1.0,
    this.maxPanX = 100000.0,
    this.maxPanY = 100000.0,
    this.enableKineticScrolling = true,
  });
}

/// A controller class for the Node Editor.
///
/// This class is responsible for managing the state of the node editor,
/// including the nodes, links, and the viewport. It also provides methods
/// for adding, removing, and manipulating nodes and links.
///
/// The controller also provides an event bus for the node editor, allowing
/// different parts of the application to communicate with each other by
/// sending and receiving events.
class FlNodeEditorController {
  // Event bus
  final eventBus = NodeEditorEventBus();

  // Behavior
  final NodeEditorBehavior behavior;

  FlNodeEditorController({
    this.behavior = const NodeEditorBehavior(),
  });

  void dispose() {
    eventBus.dispose();
  }

  // Viewport
  Offset offset = Offset.zero;
  double zoom = 1.0;

  void setViewportOffset(
    Offset coords, {
    bool animate = true,
    bool absolute = false,
  }) {
    if (absolute) {
      offset = coords;
    } else {
      offset += coords;
    }

    eventBus.emit(ViewportOffsetEvent(offset, animate: animate));
  }

  void setViewportZoom(double amount, {bool animate = true}) {
    zoom = amount;
    eventBus.emit(ViewportZoomEvent(zoom));
  }

  // This is used for rendering purposes only. For computation, use the links list in the Port class.
  final Map<String, Link> _renderLinks = {};
  Tuple2<Offset, Offset>? _renderTempLink;

  List<Link> get renderLinksAsList => _renderLinks.values.toList();
  Tuple2<Offset, Offset>? get renderTempLink => _renderTempLink;

  void drawTempLink(Offset from, Offset to) {
    _renderTempLink = Tuple2(from, to);
    eventBus.emit(DrawTempLinkEvent(from, to));
  }

  void clearTempLink() {
    _renderTempLink = null;
    eventBus.emit(DrawTempLinkEvent(Offset.zero, Offset.zero));
  }

  // Nodes and links
  final Map<String, NodePrototype Function()> _nodePrototypes = {};
  final Map<String, Node> _nodes = {};

  List<NodePrototype> get nodePrototypesAsList =>
      _nodePrototypes.values.map((e) => e()).toList();
  Map<String, NodePrototype Function()> get nodePrototypes => _nodePrototypes;
  List<Node> get nodesAsList => _nodes.values.toList();
  Map<String, Node> get nodes => _nodes;

  void registerNodePrototype(String type, NodePrototype Function() node) {
    _nodePrototypes[type] = node;
  }

  void unregisterNodePrototype(String type) {
    _nodePrototypes.remove(type);
  }

  String addNode(String type, {Offset? offset}) {
    final node = createNode(
      _nodePrototypes[type]!(),
      offset: offset,
    );

    _nodes.putIfAbsent(
      node.id,
      () => node,
    );

    eventBus.emit(AddNodeEvent(node.id));

    return node.id;
  }

  void removeNode(String id) {
    _nodes.remove(id);
    eventBus.emit(RemoveNodeEvent(id));
  }

  String addLink(
    String fromNode,
    String fromPort,
    String toNode,
    String toPort,
  ) {
    final link = Link(
      id: 'from-$fromNode-$fromPort-to-$toNode-$toPort',
      fromTo: Tuple4(fromNode, fromPort, toNode, toPort),
    );

    _renderLinks.putIfAbsent(
      link.id,
      () => link,
    );

    eventBus.emit(AddLinkEvent(link.id));

    return link.id;
  }

  void removeLink(String id) {
    _renderLinks.remove(id);
    eventBus.emit(RemoveLinkEvent(id));
  }

  void setNodeOffset(String id, Offset offset) {
    final node = _nodes[id];
    node?.offset = offset;
  }

  void collapseNode(String id) {
    final node = _nodes[id];
    node?.state.isCollapsed = true;
    eventBus.emit(CollapseNodeEvent(id));
  }

  void expandNode(String id) {
    final node = _nodes[id];
    node?.state.isCollapsed = false;
    eventBus.emit(ExpandNodeEvent(id));
  }

  // Selection
  final Set<String> _selectedNodeIds = {};
  Rect _selectionArea = Rect.zero;

  List<String> get selectedNodeIds => _selectedNodeIds.toList();
  Rect get selectionArea => _selectionArea;

  void dragSelection(Offset delta) {
    eventBus.emit(DragSelectionEvent(_selectedNodeIds.toSet(), delta));
  }

  void setSelectionArea(Rect area) {
    _selectionArea = area;
    eventBus.emit(SelectionAreaEvent(area));
  }

  void selectNodesById(List<String> ids, {bool holdSelection = false}) async {
    if (!holdSelection) {
      for (final id in _selectedNodeIds) {
        final node = _nodes[id];
        node?.state.isSelected = false;
      }

      _selectedNodeIds.clear();
    }

    _selectedNodeIds.addAll(ids);

    for (final id in _selectedNodeIds) {
      final node = _nodes[id];
      node?.state.isSelected = true;
    }

    eventBus.emit(SelectionEvent(_selectedNodeIds.toSet()));
  }

  void selectNodesByArea({bool holdSelection = false}) async {
    final containedNodes = <String>[];

    for (final node in _nodes.values) {
      final nodeBounds = getNodeBoundsInWorld(node);
      if (nodeBounds == null) continue;

      if (_selectionArea.overlaps(nodeBounds)) {
        containedNodes.add(node.id);
      }
    }

    selectNodesById(containedNodes, holdSelection: holdSelection);

    _selectionArea = Rect.zero;
  }

  void clearSelection() {
    for (final id in _selectedNodeIds) {
      final node = _nodes[id];
      node?.state.isSelected = false;
    }

    _selectedNodeIds.clear();
    eventBus.emit(SelectionEvent(_selectedNodeIds.toSet()));
  }

  void focusNodesById(List<String> ids) {
    Rect encompassingRect = Rect.zero;

    for (final id in ids) {
      final nodeBounds = getNodeBoundsInWorld(_nodes[id]!);
      if (nodeBounds == null) continue;

      if (encompassingRect.isEmpty) {
        encompassingRect = nodeBounds;
      } else {
        encompassingRect = encompassingRect.expandToInclude(nodeBounds);
      }
    }

    selectNodesById(ids, holdSelection: false);

    final nodeEditorSize = getSizeFromGlobalKey(kNodeEditorWidgetKey)!;
    final paddedEncompassingRect = encompassingRect.inflate(50.0);
    final fitZoom = min(
      nodeEditorSize.width / paddedEncompassingRect.width,
      nodeEditorSize.height / paddedEncompassingRect.height,
    );

    setViewportZoom(fitZoom, animate: true);
    setViewportOffset(
      -encompassingRect.center,
      animate: true,
      absolute: true,
    );
  }

  Future<List<String>> searchNodesByName(String name) async {
    final results = <String>[];

    for (final node in _nodes.values) {
      if (node.name.toLowerCase().contains(name.toLowerCase())) {
        results.add(node.id);
      }
    }

    return results;
  }
}
