// Copyright (c) 2013, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

/// This is for use in extracting messages from a Dart program
/// using the Intl.message() mechanism and writing them to a file for
/// translation. This provides only the stub of a mechanism, because it
/// doesn't define how the file should be written. It provides an
/// [IntlMessage] class that holds the extracted data and [parseString]
/// and [parseFile] methods which
/// can extract messages that conform to the expected pattern:
///       (parameters) => Intl.message("Message $parameters", desc: ...);
/// It uses the analyzer package to do the parsing, so may
/// break if there are changes to the API that it provides.
/// An example can be found in test/message_extraction/extract_to_json.dart
///
/// Note that this does not understand how to follow part directives, so it
/// has to explicitly be given all the files that it needs. A typical use case
/// is to run it on all .dart files in a directory.
library extract_messages;

import 'dart:io';

import 'package:analyzer/dart/analysis/utilities.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/visitor.dart';
import 'package:analyzer/src/dart/ast/constant_evaluator.dart';
import 'package:intl_translation/src/intl_message.dart';

/// A function that takes a message and does something useful with it.
typedef void OnMessage(String message);

/// A particular message extraction run.
///
///  This encapsulates all the state required for message extraction so that
///  it can be run inside a persistent process.
class MessageExtraction {
  /// What to do when a message is encountered, defaults to [print].
  OnMessage onMessage = print;

  /// If this is true, the @@last_modified entry is not output.
  bool suppressLastModified = false;

  /// If this is true, print warnings for skipped messages. Otherwise, warnings
  /// are suppressed.
  bool suppressWarnings = false;

  /// If this is true, no translation meta data is written
  bool suppressMetaData = false;

  /// If this is true, then treat all warnings as errors.
  bool warningsAreErrors = false;

  /// This accumulates a list of all warnings/errors we have found. These are
  /// saved as strings right now, so all that can really be done is print and
  /// count them.
  List<String> warnings = [];

  /// Were there any warnings or errors in extracting messages.
  bool get hasWarnings => warnings.isNotEmpty;

  /// Are plural and gender expressions required to be at the top level
  /// of an expression, or are they allowed to be embedded in string literals.
  ///
  /// For example, the following expression
  ///     'There are ${Intl.plural(...)} items'.
  /// is legal if [allowEmbeddedPluralsAndGenders] is true, but illegal
  /// if [allowEmbeddedPluralsAndGenders] is false.
  bool allowEmbeddedPluralsAndGenders = true;

  /// Are examples required on all messages.
  bool examplesRequired = false;

  bool descriptionRequired = false;

  /// Whether to include source_text in messages
  bool includeSourceText = false;

  /// Parse the source of the Dart program file [file] and return a Map from
  /// message names to [IntlMessage] instances.
  ///
  /// If [transformer] is true, assume the transformer will supply any "name"
  /// and "args" parameters required in Intl.message calls.
  Map<String, MainMessage> parseFile(File file, [bool? transformer = false]) {
    String contents = file.readAsStringSync();
    return parseContent(contents, file.path, transformer);
  }

  /// Parse the source of the Dart program from a file with content
  /// [fileContent] and path [path] and return a Map from message
  /// names to [IntlMessage] instances.
  ///
  /// If [transformer] is true, assume the transformer will supply any "name"
  /// and "args" parameters required in Intl.message calls.
  Map<String, MainMessage> parseContent(String fileContent, String filepath,
      [bool? transformer = false]) {
    String contents = fileContent;
    origin = filepath;
    // Optimization to avoid parsing files we're sure don't contain any messages.
    if (contents.contains('Intl.')) {
      root = _parseCompilationUnit(contents, origin);
    } else {
      return {};
    }
    var visitor = new MessageFindingVisitor(this);
    visitor.generateNameAndArgs = transformer;
    root.accept(visitor);
    return visitor.messages;
  }

  CompilationUnit _parseCompilationUnit(String contents, String? origin) {
    var result = parseString(content: contents, throwIfDiagnostics: false);

    if (result.errors.isNotEmpty) {
      print("Error in parsing $origin, no messages extracted.");
      throw ArgumentError('Parsing errors in $origin');
    }

    return result.unit;
  }

  /// The root of the compilation unit, and the first node we visit. We hold
  /// on to this for error reporting, as it can give us line numbers of other
  /// nodes.
  late CompilationUnit root;

  /// An arbitrary string describing where the source code came from. Most
  /// obviously, this could be a file path. We use this when reporting
  /// invalid messages.
  String? origin;

  String _reportErrorLocation(AstNode node) {
    var result = new StringBuffer();
    if (origin != null) result.write("    from $origin");
    var info = root.lineInfo;
    if (info != null) {
      var line = info.getLocation(node.offset);
      result
          .write("    line: ${line.lineNumber}, column: ${line.columnNumber}");
    }
    return result.toString();
  }
}

/// This visits the program source nodes looking for Intl.message uses
/// that conform to its pattern and then creating the corresponding
/// IntlMessage objects. We have to find both the enclosing function, and
/// the Intl.message invocation.
class MessageFindingVisitor extends GeneralizingAstVisitor {
  MessageFindingVisitor(this.extraction);

  /// The message extraction in which we are running.
  final MessageExtraction extraction;

  /// Accumulates the messages we have found, keyed by name.
  final Map<String, MainMessage> messages = new Map<String, MainMessage>();

  /// Should we generate the name and arguments from the function definition,
  /// meaning we're running in the transformer.
  bool? generateNameAndArgs = false;

  /// We keep track of the data from the last MethodDeclaration,
  /// FunctionDeclaration or FunctionExpression that we saw on the way down,
  /// as that will be the nearest parent of the Intl.message invocation.
  FormalParameterList? parameters;
  String? name;

  /// Return true if [node] matches the pattern we expect for Intl.message()
  bool looksLikeIntlMessage(MethodInvocation node) {
    const validNames = const ["message", "plural", "gender", "select"];
    if (!validNames.contains(node.methodName.name)) return false;
    final target = node.target;
    if (target is SimpleIdentifier) {
      return target.token.toString() == 'Intl';
    } else if (target is PrefixedIdentifier) {
      return target.identifier.token.toString() == 'Intl';
    }
    return false;
  }

  Message? _expectedInstance(String type) {
    switch (type) {
      case 'message':
        return new MainMessage();
      case 'plural':
        return new Plural();
      case 'gender':
        return new Gender();
      case 'select':
        return new Select();
      default:
        return null;
    }
  }

  /// Returns a String describing why the node is invalid, or null if no
  /// reason is found, so it's presumed valid.
  String? checkValidity(MethodInvocation node) {
    if (parameters == null) {
      return "Calls to Intl must be inside a method, field declaration or "
          "top level declaration.";
    }
    // The containing function cannot have named parameters.
    if (parameters!.parameters.any((each) => each.isNamed)) {
      return "Named parameters on message functions are not supported.";
    }
    var arguments = node.argumentList.arguments;
    var instance = _expectedInstance(node.methodName.name)!;
    return instance.checkValidity(node, arguments, name, parameters!,
        nameAndArgsGenerated: generateNameAndArgs!,
        examplesRequired: extraction.examplesRequired);
  }

  /// Record the parameters of the function or method declaration we last
  /// encountered before seeing the Intl.message call.
  void visitMethodDeclaration(MethodDeclaration node) {
    name = node.name.name;
    parameters = node.parameters;
    super.visitMethodDeclaration(node);
    name = null;
    parameters = null;
  }

  /// Record the parameters of the function or method declaration we last
  /// encountered before seeing the Intl.message call.
  void visitFunctionDeclaration(FunctionDeclaration node) {
    name = node.name.name;
    parameters = node.functionExpression.parameters;
    super.visitFunctionDeclaration(node);
    name = null;
    parameters = null;
  }

  /// Record the name of field declaration we last
  /// encountered before seeing the Intl.message call.
  void visitFieldDeclaration(FieldDeclaration node) {
    // We don't support names in list declarations,
    // e.g. String first, second = Intl.message(...);
    if (node.fields.variables.length == 1) {
      name = node.fields.variables.first.name.name;
    } else {
      name = null;
    }
    super.visitFieldDeclaration(node);
    name = null;
    parameters = null;
  }

  /// Record the name of the top level variable declaration we last
  /// encountered before seeing the Intl.message call.
  void visitTopLevelVariableDeclaration(TopLevelVariableDeclaration node) {
    // We don't support names in list declarations,
    // e.g. String first, second = Intl.message(...);
    if (node.variables.variables.length == 1) {
      name = node.variables.variables.first.name.name;
    } else {
      name = null;
    }
    super.visitTopLevelVariableDeclaration(node);
    name = null;
    parameters = null;
  }

  /// Examine method invocations to see if they look like calls to Intl.message.
  /// If we've found one, stop recursing. This is important because we can have
  /// Intl.message(...Intl.plural...) and we don't want to treat the inner
  /// plural as if it was an outermost message.
  void visitMethodInvocation(MethodInvocation node) {
    if (!addIntlMessage(node)) {
      super.visitMethodInvocation(node);
    }
  }

  /// Check that the node looks like an Intl.message invocation, and create
  /// the [IntlMessage] object from it and store it in [messages]. Return true
  /// if we successfully extracted a message and should stop looking. Return
  /// false if we didn't, so should continue recursing.
  bool addIntlMessage(MethodInvocation node) {
    if (!looksLikeIntlMessage(node)) return false;
    var reason = checkValidity(node) ?? _extractMessage(node);

    if (reason != null) {
      if (!extraction.suppressWarnings) {
        var err = new StringBuffer()
          ..write("Skipping invalid Intl.message invocation\n    <$node>\n")
          ..writeAll(
              ["    reason: $reason\n", extraction._reportErrorLocation(node)]);
        var errString = err.toString();
        extraction.warnings.add(errString);
        extraction.onMessage(errString);
      }
    }

    // We found a message, valid or not. Stop recursing.
    return true;
  }

  /// Try to extract a message. On failure, return a String error message.
  String? _extractMessage(MethodInvocation node) {
    MainMessage? message;
    try {
      if (node.methodName.name == "message") {
        message = messageFromIntlMessageCall(node);
      } else {
        message = messageFromDirectPluralOrGenderCall(node);
      }
    } catch (e, s) {
      return "Unexpected exception: $e, $s";
    }
    return message == null ? null : _validateMessage(message);
  }

  /// Perform any post-construction validations on the message and
  /// ensure that it's not a duplicate.
  // TODO(alanknight): This is still ugly and may lead to duplicate reporting
  // of the same error. Refactor to consistently throw
  // IntlMessageExtractionException instead of returning strings and centralize
  // the reporting.
  String? _validateMessage(MainMessage message) {
    try {
      message.validate();
      if (extraction.descriptionRequired) {
        message.validateDescription();
      }
    } on IntlMessageExtractionException catch (e) {
      return e.message;
    }
    var existing = messages[message.name];
    if (existing != null) {
      // TODO(alanknight): We may want to require the descriptions to match.
      var existingCode =
          existing.toOriginalCode(includeDesc: false, includeExamples: false);
      var messageCode =
          message.toOriginalCode(includeDesc: false, includeExamples: false);
      if (existingCode != messageCode) {
        return "WARNING: Duplicate message name:\n"
            "'${message.name}' occurs more than once in ${extraction.origin}";
      }
    } else {
      if (!message.skip!) {
        messages[message.name] = message;
      }
      return null;
    }
    return null; // Placate the analyzer
  }

  /// Create a MainMessage from [node] using the name and
  /// parameters of the last function/method declaration we encountered,
  /// and the values we get by calling [extract]. We set those values
  /// by calling [setAttribute]. This is the common parts between
  /// [messageFromIntlMessageCall] and [messageFromDirectPluralOrGenderCall].
  MainMessage? _messageFromNode(
      MethodInvocation node,
      MainMessage? extract(MainMessage? message, List<AstNode> arguments),
      void setAttribute(
          MainMessage message, String fieldName, Object? fieldValue)) {
    var message = new MainMessage();
    message.sourcePosition = node.offset;
    message.endPosition = node.end;
    message.arguments =
        parameters!.parameters.map((x) => x.identifier!.name).toList();
    var arguments = node.argumentList.arguments;
    var extractionResult = extract(message, arguments);
    if (extractionResult == null) return null;

    for (var namedArgument in arguments.whereType<NamedExpression>()) {
      var name = namedArgument.name.label.name;
      var exp = namedArgument.expression;
      var evaluator = new ConstantEvaluator();
      var basicValue = exp.accept(evaluator);
      var value = basicValue == ConstantEvaluator.NOT_A_CONSTANT
          ? exp.toString()
          : basicValue;
      setAttribute(message, name, value);
    }
    // We only rewrite messages with parameters, otherwise we use the literal
    // string as the name and no arguments are necessary.
    if (!message.hasName) {
      if (generateNameAndArgs! && message.arguments!.isNotEmpty) {
        // Always try for class_method if this is a class method and
        // generating names/args.
        message.name = Message.classPlusMethodName(node, name) ?? name;
      } else if (arguments.first is SimpleStringLiteral ||
          arguments.first is AdjacentStrings) {
        // If there's no name, and the message text is a simple string, compute
        // a name based on that plus meaning, if present.
        var simpleName = (arguments.first as StringLiteral).stringValue;
        message.name =
            computeMessageName(message.name, simpleName, message.meaning);
      }
    }
    return message;
  }

  /// Find the message pieces from a Dart interpolated string.
  List _extractFromIntlCallWithInterpolation(
      MainMessage message, List<AstNode> arguments) {
    var interpolation = new InterpolationVisitor(message, extraction);
    arguments.first.accept(interpolation);
    if (interpolation.pieces.any((x) => x is Plural || x is Gender) &&
        !extraction.allowEmbeddedPluralsAndGenders) {
      if (interpolation.pieces.any((x) => x is String && x.isNotEmpty)) {
        throw new IntlMessageExtractionException(
            "Plural and gender expressions must be at the top level, "
            "they cannot be embedded in larger string literals.\n");
      }
    }
    return interpolation.pieces;
  }

  /// Create a MainMessage from [node] using the name and
  /// parameters of the last function/method declaration we encountered
  /// and the parameters to the Intl.message call.
  MainMessage? messageFromIntlMessageCall(MethodInvocation node) {
    MainMessage? extractFromIntlCall(
        MainMessage? message, List<AstNode> arguments) {
      try {
        // The pieces of the message, either literal strings, or integers
        // representing the index of the argument to be substituted.
        List extracted;
        extracted = _extractFromIntlCallWithInterpolation(message!, arguments);
        message.addPieces(extracted as List<Object>);
      } on IntlMessageExtractionException catch (e) {
        message = null;
        var err = new StringBuffer()
          ..writeAll(["Error ", e, "\nProcessing <", node, ">\n"])
          ..write(extraction._reportErrorLocation(node));
        var errString = err.toString();
        extraction.onMessage(errString);
        extraction.warnings.add(errString);
      }
      return message;
    }

    void setValue(MainMessage message, String fieldName, Object? fieldValue) {
      message[fieldName] = fieldValue;
    }

    return _messageFromNode(node, extractFromIntlCall, setValue);
  }

  /// Create a MainMessage from [node] using the name and
  /// parameters of the last function/method declaration we encountered
  /// and the parameters to the Intl.plural or Intl.gender call.
  MainMessage? messageFromDirectPluralOrGenderCall(MethodInvocation node) {
    MainMessage extractFromPluralOrGender(MainMessage? message, _) {
      var visitor = new PluralAndGenderVisitor(
          message!.messagePieces, message, extraction);
      node.accept(visitor);
      return message;
    }

    void setAttribute(MainMessage msg, String fieldName, fieldValue) {
      if (msg.attributeNames.contains(fieldName)) {
        msg[fieldName] = fieldValue;
      }
    }

    return _messageFromNode(node, extractFromPluralOrGender, setAttribute);
  }
}

/// Given an interpolation, find all of its chunks, validate that they are only
/// simple variable substitutions or else Intl.plural/gender calls,
/// and keep track of the pieces of text so that other parts
/// of the program can deal with the simple string sections and the generated
/// parts separately. Note that this is a SimpleAstVisitor, so it only
/// traverses one level of children rather than automatically recursing. If we
/// find a plural or gender, which requires recursion, we do it with a separate
/// special-purpose visitor.
class InterpolationVisitor extends SimpleAstVisitor {
  final Message? message;

  /// The message extraction in which we are running.
  final MessageExtraction extraction;

  InterpolationVisitor(this.message, this.extraction);

  List pieces = [];
  String get extractedMessage => pieces.join();

  void visitAdjacentStrings(AdjacentStrings node) {
    node.visitChildren(this);
    super.visitAdjacentStrings(node);
  }

  void visitStringInterpolation(StringInterpolation node) {
    node.visitChildren(this);
    super.visitStringInterpolation(node);
  }

  void visitSimpleStringLiteral(SimpleStringLiteral node) {
    pieces.add(node.value);
    super.visitSimpleStringLiteral(node);
  }

  void visitInterpolationString(InterpolationString node) {
    pieces.add(node.value);
    super.visitInterpolationString(node);
  }

  void visitInterpolationExpression(InterpolationExpression node) {
    if (node.expression is SimpleIdentifier) {
      handleSimpleInterpolation(node);
    } else {
      lookForPluralOrGender(node);
    }
    // Note that we never end up calling super.
  }

  void lookForPluralOrGender(InterpolationExpression node) {
    var visitor = new PluralAndGenderVisitor(
        pieces, message as ComplexMessage?, extraction);
    node.accept(visitor);
    if (!visitor.foundPluralOrGender) {
      throw new IntlMessageExtractionException(
          "Only simple identifiers and Intl.plural/gender/select expressions "
          "are allowed in message "
          "interpolation expressions.\nError at $node");
    }
  }

  void handleSimpleInterpolation(InterpolationExpression node) {
    var index = arguments!.indexOf(node.expression.toString());
    if (index == -1) {
      throw new IntlMessageExtractionException(
          "Cannot find argument ${node.expression}");
    }
    pieces.add(index);
  }

  List? get arguments => message!.arguments;
}

/// A visitor to extract information from Intl.plural/gender sends. Note that
/// this is a SimpleAstVisitor, so it doesn't automatically recurse. So this
/// needs to be called where we expect a plural or gender immediately below.
class PluralAndGenderVisitor extends SimpleAstVisitor {
  /// The message extraction in which we are running.
  final MessageExtraction extraction;

  /// A plural or gender always exists in the context of a parent message,
  /// which could in turn also be a plural or gender.
  final ComplexMessage? parent;

  /// The pieces of the message. We are given an initial version of this
  /// from our parent and we add to it as we find additional information.
  List pieces;

  /// This will be set to true if we find a plural or gender.
  bool foundPluralOrGender = false;

  PluralAndGenderVisitor(this.pieces, this.parent, this.extraction) : super();

  visitInterpolationExpression(InterpolationExpression node) {
    // TODO(alanknight): Provide better errors for malformed expressions.
    if (!looksLikePluralOrGender(node.expression)) return;
    var reason = checkValidity(node.expression as MethodInvocation);
    if (reason != null) throw reason;
    var message =
        messageFromMethodInvocation(node.expression as MethodInvocation);
    foundPluralOrGender = true;
    pieces.add(message);
    super.visitInterpolationExpression(node);
  }

  visitMethodInvocation(MethodInvocation node) {
    pieces.add(messageFromMethodInvocation(node));
    super.visitMethodInvocation(node);
  }

  /// Return true if [node] matches the pattern for plural or gender message.
  bool looksLikePluralOrGender(Expression expression) {
    if (expression is! MethodInvocation) return false;
    final node = expression;
    if (!["plural", "gender", "select"].contains(node.methodName.name)) {
      return false;
    }
    if (!(node.target is SimpleIdentifier)) return false;
    SimpleIdentifier target = node.target as SimpleIdentifier;
    return target.token.toString() == "Intl";
  }

  /// Returns a String describing why the node is invalid, or null if no
  /// reason is found, so it's presumed valid.
  String? checkValidity(MethodInvocation node) {
    // TODO(alanknight): Add reasonable validity checks.
    return null;
  }

  /// Create a MainMessage from [node] using the name and
  /// parameters of the last function/method declaration we encountered
  /// and the parameters to the Intl.message call.
  Message? messageFromMethodInvocation(MethodInvocation node) {
    var message;
    switch (node.methodName.name) {
      case "gender":
        message = new Gender();
        break;
      case "plural":
        message = new Plural();
        break;
      case "select":
        message = new Select();
        break;
      default:
        throw new IntlMessageExtractionException(
            "Invalid plural/gender/select message ${node.methodName.name} "
            "in $node");
    }
    message.parent = parent;

    var arguments = message.argumentsOfInterestFor(node);
    arguments.forEach((key, value) {
      try {
        var interpolation = new InterpolationVisitor(message, extraction);
        value.accept(interpolation);
        // Might be null due to previous errors.
        // Continue collecting errors, but don't build message.
        if (message != null) {
          message[key] = interpolation.pieces;
        }
      } on IntlMessageExtractionException catch (e) {
        message = null;
        var err = new StringBuffer()
          ..writeAll(["Error ", e, "\nProcessing <", node, ">"])
          ..write(extraction._reportErrorLocation(node));
        var errString = err.toString();
        extraction.onMessage(errString);
        extraction.warnings.add(errString);
      }
    });
    var mainArg = node.argumentList.arguments
        .firstWhere((each) => each is! NamedExpression);
    if (mainArg is SimpleStringLiteral) {
      message.mainArgument = mainArg.toString();
    } else if (mainArg is SimpleIdentifier) {
      message.mainArgument = mainArg.name;
    } else {
      var err = new StringBuffer()
        ..write("Error (Invalid argument to plural/gender/select, "
            "must be simple variable reference) "
            "\nProcessing <$node>")
        ..write(extraction._reportErrorLocation(node));
      var errString = err.toString();
      extraction.onMessage(errString);
      extraction.warnings.add(errString);
    }
    return message;
  }
}

/// If a message is a string literal without interpolation, compute
/// a name based on that and the meaning, if present.
// NOTE: THIS LOGIC IS DUPLICATED IN intl AND THE TWO MUST MATCH.
String? computeMessageName(String name, String? text, String? meaning) {
  if (name != null && name != "") return name;
  return meaning == null ? text : "${text}_${meaning}";
}
