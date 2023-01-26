// Copyright (c) 2022, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'dart:math';

import 'package:dart2wasm/class_info.dart';
import 'package:dart2wasm/param_info.dart';
import 'package:dart2wasm/reference_extensions.dart';
import 'package:dart2wasm/translator.dart';

import 'package:kernel/ast.dart';

import 'package:vm/metadata/procedure_attributes.dart';
import 'package:vm/metadata/table_selector.dart';

import 'package:wasm_builder/wasm_builder.dart' as w;

/// Information for a dispatch table selector.
///
/// A selector encapsulates information to generate code that selects the right
/// member (method, getter, setter) implementation in an instance invocation,
/// from the dispatch table. Dispatch table is generated by [DispatchTable].
///
/// Target of a selector is a method, getter, or setter [Reference]. A target
/// does not have to correspond to a user-written Dart member, it can be for a
/// generated one. For example, for torn-off methods, we generate a [Reference]
/// for the tear-off getter a selector for it.
class SelectorInfo {
  final Translator translator;

  /// Unique ID of the selector.
  final int id;

  /// Number of use sites of the selector.
  final int callCount;

  /// Least upper bound of [ParameterInfo]s of all targets.
  final ParameterInfo paramInfo;

  /// Number of Wasm return values of the selector's targets.
  ///
  /// BUG(50458): This should always be 1.
  int _returnCount;

  /// Maps class IDs to the selector's member in the class. The member can be
  /// abstract.
  final Map<int, Reference> targets = {};

  /// Wasm function type for the selector.
  ///
  /// This should be read after all targets have been added to the selector.
  late final w.FunctionType signature = _computeSignature();

  /// IDs of classes that implement the member. This does not include abstract
  /// classes.
  late final List<int> classIds;

  /// Number of non-abstract references in [targets].
  late final int targetCount;

  /// When [targetCount] is 1, this holds the only non-abstract target of the
  /// selector.
  late final Reference? singularTarget;

  /// Offset of the selector in the dispatch table.
  ///
  /// For a class in [targets], `class ID + offset` gives the offset of the
  /// class member for this selector.
  int? offset;

  w.Module get m => translator.m;

  /// The selector's member's name.
  String get name => paramInfo.member!.name.text;

  SelectorInfo._(this.translator, this.id, this.callCount, this.paramInfo,
      this._returnCount);

  /// Compute the signature for the functions implementing members targeted by
  /// this selector.
  ///
  /// When the selector has multiple targets, the type of each parameter/return
  /// is the upper bound across all targets, such that all targets have the
  /// same signature, and the actual representation types of the parameters and
  /// returns are subtypes (resp. supertypes) of the types in the signature.
  w.FunctionType _computeSignature() {
    var nameIndex = paramInfo.nameIndex;
    List<Set<ClassInfo>> inputSets =
        List.generate(1 + paramInfo.paramCount, (_) => {});
    List<Set<ClassInfo>> outputSets = List.generate(_returnCount, (_) => {});
    List<bool> inputNullable = List.filled(1 + paramInfo.paramCount, false);
    List<bool> ensureBoxed = List.filled(1 + paramInfo.paramCount, false);
    List<bool> outputNullable = List.filled(_returnCount, false);
    targets.forEach((classId, target) {
      ClassInfo receiver = translator.classes[classId];
      List<DartType> positional;
      Map<String, DartType> named;
      List<DartType> returns;
      Member member = target.asMember;
      if (member is Field) {
        if (target.isImplicitGetter) {
          positional = const [];
          named = const {};
          returns = [member.getterType];
        } else {
          positional = [member.setterType];
          named = const {};
          returns = const [];
        }
      } else {
        FunctionNode function = member.function!;
        if (target.isTearOffReference) {
          positional = const [];
          named = const {};
          returns = [function.computeFunctionType(Nullability.nonNullable)];
        } else {
          positional = [
            for (VariableDeclaration param in function.positionalParameters)
              param.type
          ];
          named = {
            for (VariableDeclaration param in function.namedParameters)
              param.name!: param.type
          };
          returns = function.returnType is VoidType
              ? const []
              : [function.returnType];

          // Box parameters that need covariance checks
          for (int i = 0; i < function.positionalParameters.length; i += 1) {
            final param = function.positionalParameters[i];
            ensureBoxed[1 + i] |=
                param.isCovariantByClass || param.isCovariantByDeclaration;
          }
          for (VariableDeclaration param in function.namedParameters) {
            ensureBoxed[1 + nameIndex[param.name!]!] |=
                param.isCovariantByClass || param.isCovariantByDeclaration;
          }
        }
      }
      assert(returns.length <= outputSets.length);
      inputSets[0].add(receiver);
      ensureBoxed[0] = true;
      for (int i = 0; i < positional.length; i++) {
        DartType type = positional[i];
        inputSets[1 + i]
            .add(translator.classInfo[translator.classForType(type)]!);
        inputNullable[1 + i] |= type.isPotentiallyNullable;
        ensureBoxed[1 + i] |=
            paramInfo.positional[i] == ParameterInfo.defaultValueSentinel;
      }
      for (String name in named.keys) {
        int i = nameIndex[name]!;
        DartType type = named[name]!;
        inputSets[1 + i]
            .add(translator.classInfo[translator.classForType(type)]!);
        inputNullable[1 + i] |= type.isPotentiallyNullable;
        ensureBoxed[1 + i] |=
            paramInfo.named[name] == ParameterInfo.defaultValueSentinel;
      }
      for (int i = 0; i < _returnCount; i++) {
        if (i < returns.length) {
          outputSets[i]
              .add(translator.classInfo[translator.classForType(returns[i])]!);
          outputNullable[i] |= returns[i].isPotentiallyNullable;
        } else {
          outputNullable[i] = true;
        }
      }
    });

    List<w.ValueType> typeParameters = List.filled(paramInfo.typeParamCount,
        translator.classInfo[translator.typeClass]!.nonNullableType);
    List<w.ValueType> inputs = List.generate(
        inputSets.length,
        (i) => translator.typeForInfo(
            upperBound(inputSets[i]), inputNullable[i],
            ensureBoxed: ensureBoxed[i]) as w.ValueType);
    if (name == '==') {
      // == can't be called with null
      inputs[1] = inputs[1].withNullability(false);
    }
    List<w.ValueType> outputs = List.generate(
        outputSets.length,
        (i) => translator.typeForInfo(
            upperBound(outputSets[i]), outputNullable[i]) as w.ValueType);
    return m.addFunctionType(
        [inputs[0], ...typeParameters, ...inputs.sublist(1)], outputs);
  }
}

/// Builds the dispatch table for member calls.
class DispatchTable {
  final Translator translator;
  final List<TableSelectorInfo> _selectorMetadata;
  final Map<TreeNode, ProcedureAttributesMetadata> _procedureAttributeMetadata;

  /// Maps selector IDs to selectors.
  final Map<int, SelectorInfo> _selectorInfo = {};

  /// Maps member names to getter selectors with the same member name.
  final Map<String, List<SelectorInfo>> _dynamicGetters = {};

  /// Maps member names to setter selectors with the same member name.
  final Map<String, List<SelectorInfo>> _dynamicSetters = {};

  /// Maps member names to method selectors with the same member name.
  final Map<String, List<SelectorInfo>> _dynamicMethods = {};

  /// Contents of [wasmTable]. For a selector with ID S and a target class of
  /// the selector with ID C, `table[S + C]` gives the reference to the class
  /// member for the selector.
  late final List<Reference?> _table;

  /// The Wasm table for the dispatch table.
  late final w.DefinedTable wasmTable;

  w.Module get m => translator.m;

  DispatchTable(this.translator)
      : _selectorMetadata =
            (translator.component.metadata["vm.table-selector.metadata"]
                    as TableSelectorMetadataRepository)
                .mapping[translator.component]!
                .selectors,
        _procedureAttributeMetadata =
            (translator.component.metadata["vm.procedure-attributes.metadata"]
                    as ProcedureAttributesMetadataRepository)
                .mapping;

  SelectorInfo selectorForTarget(Reference target) {
    Member member = target.asMember;
    bool isGetter = target.isGetter || target.isTearOffReference;
    ProcedureAttributesMetadata metadata = _procedureAttributeMetadata[member]!;
    int selectorId = isGetter
        ? metadata.getterSelectorId
        : metadata.methodOrSetterSelectorId;
    return _selectorInfo[selectorId]!;
  }

  SelectorInfo _createSelectorForTarget(Reference target) {
    Member member = target.asMember;
    bool isGetter = target.isGetter || target.isTearOffReference;
    bool isSetter = target.isSetter;
    ProcedureAttributesMetadata metadata = _procedureAttributeMetadata[member]!;
    int selectorId = isGetter
        ? metadata.getterSelectorId
        : metadata.methodOrSetterSelectorId;
    ParameterInfo paramInfo = ParameterInfo.fromMember(target);
    final int returnCount = (isGetter && member.getterType is! VoidType) ||
            (member is Procedure && member.function.returnType is! VoidType)
        ? 1
        : 0;

    // _WasmBase and its subclass methods cannot be called dynamically
    final cls = member.enclosingClass;
    final isWasmType = cls != null && translator.isWasmType(cls);

    final calledDynamically = !isWasmType &&
        (metadata.getterCalledDynamically ||
            metadata.methodOrSetterCalledDynamically ||
            member.name.text == "call");

    final selector = _selectorInfo.putIfAbsent(
        selectorId,
        () => SelectorInfo._(translator, selectorId,
            _selectorMetadata[selectorId].callCount, paramInfo, returnCount));
    selector.paramInfo.merge(paramInfo);
    selector._returnCount = max(selector._returnCount, returnCount);
    if (calledDynamically) {
      if (isGetter) {
        (_dynamicGetters[member.name.text] ??= []).add(selector);
      } else if (isSetter) {
        (_dynamicSetters[member.name.text] ??= []).add(selector);
      } else {
        (_dynamicMethods[member.name.text] ??= []).add(selector);
      }
    }
    return selector;
  }

  /// Get selectors for getters and tear-offs with the given name.
  Iterable<SelectorInfo> dynamicGetterSelectors(String memberName) =>
      _dynamicGetters[memberName] ?? Iterable.empty();

  /// Get selectors for setters with the given name.
  Iterable<SelectorInfo> dynamicSetterSelectors(String memberName) =>
      _dynamicSetters[memberName] ?? Iterable.empty();

  /// Get selectors for methods with the given name.
  Iterable<SelectorInfo> dynamicMethodSelectors(String memberName) =>
      _dynamicMethods[memberName] ?? Iterable.empty();

  void build() {
    // Collect class/selector combinations

    // Maps class IDs to selector IDs of the class
    List<Set<int>> selectorsInClass = [];

    // Add classes to selector targets for their members
    for (ClassInfo info in translator.classes) {
      Set<int> selectorIds = {};
      final ClassInfo? superInfo = info.superInfo;

      // Add the class to its inherited members' selectors. Skip `_WasmBase`:
      // it's defined as a Dart class (in `dart.wasm` library) but it's special
      // and does not inherit from `Object`.
      if (superInfo != null && info.cls != translator.wasmTypesBaseClass) {
        int superId = superInfo.classId;
        selectorIds = Set.of(selectorsInClass[superId]);
        for (int selectorId in selectorIds) {
          SelectorInfo selector = _selectorInfo[selectorId]!;
          selector.targets[info.classId] = selector.targets[superId]!;
        }
      }

      /// Add a method (or getter, setter) of the current class ([info]) to
      /// [reference]'s selector's targets.
      ///
      /// Because we visit a superclass before its subclasses, if the class
      /// inherits [reference], then the selector will already have a target
      /// for the class. Override that target if [reference] is a not abstract.
      /// If it's abstract, then the superclass's method will be called, so do
      /// not update the target.
      void addMember(Reference reference) {
        SelectorInfo selector = _createSelectorForTarget(reference);
        if (reference.asMember.isAbstract) {
          // Reference is abstract, do not override inherited concrete member
          selector.targets[info.classId] ??= reference;
        } else {
          // Reference is concrete, override inherited member
          selector.targets[info.classId] = reference;
        }
        selectorIds.add(selector.id);
      }

      // Add the class to its non-static members' selectors. If `info.cls` is
      // `null`, that means [info] represents the `#Top` type, which is not a
      // Dart class but has the members of `Object`.
      for (Member member
          in info.cls?.members ?? translator.coreTypes.objectClass.members) {
        // Skip static members
        if (!member.isInstanceMember) {
          continue;
        }
        if (member is Field) {
          addMember(member.getterReference);
          if (member.hasSetter) addMember(member.setterReference!);
        } else if (member is Procedure) {
          addMember(member.reference);
          // `hasTearOffUses` can be true for operators as well, even though
          // it's not possible to tear-off an operator. (no syntax for it)
          if (member.kind == ProcedureKind.Method &&
              _procedureAttributeMetadata[member]!.hasTearOffUses) {
            addMember(member.tearOffReference);
          }
        }
      }

      selectorsInClass.add(selectorIds);
    }

    // Build lists of class IDs and count targets
    for (SelectorInfo selector in _selectorInfo.values) {
      selector.classIds = selector.targets.keys
          .where((classId) =>
              !(translator.classes[classId].cls?.isAbstract ?? true))
          .toList()
        ..sort();
      Set<Reference> targets =
          selector.targets.values.where((t) => !t.asMember.isAbstract).toSet();
      selector.targetCount = targets.length;
      selector.singularTarget = targets.length == 1 ? targets.single : null;
    }

    // Assign selector offsets

    /// Whether the selector will be used in an instance invocation.
    ///
    /// If not, then we don't add the selector to the dispatch table and don't
    /// assign it a dispatch table offset.
    ///
    /// Special case for `objectNoSuchMethod`: we introduce instance
    /// invocations of `objectNoSuchMethod` in dynamic calls, so keep it alive
    /// even if there was no references to it from the Dart code.
    bool needsDispatch(SelectorInfo selector) =>
        (selector.callCount > 0 && selector.targetCount > 1) ||
        (selector.paramInfo.member! == translator.objectNoSuchMethod);

    List<SelectorInfo> selectors =
        _selectorInfo.values.where(needsDispatch).toList();

    // Sort the selectors based on number of targets and number of use sites.
    // This is a heuristic to keep the table small.
    //
    // Place selectors with more targets first as they are less likely to fit
    // into the gaps left by selectors placed earlier.
    //
    // Among the selectors with approximately same number of targets, place
    // more used ones first, as the smaller selector offset will have a smaller
    // instruction encoding.
    int selectorSortWeight(SelectorInfo selector) =>
        selector.classIds.length * 10 + selector.callCount;

    selectors.sort((a, b) => selectorSortWeight(b) - selectorSortWeight(a));

    int firstAvailable = 0;
    _table = [];
    bool first = true;
    for (SelectorInfo selector in selectors) {
      int offset = first ? 0 : firstAvailable - selector.classIds.first;
      first = false;
      bool fits;
      do {
        fits = true;
        for (int classId in selector.classIds) {
          int entry = offset + classId;
          if (entry >= _table.length) {
            // Fits
            break;
          }
          if (_table[entry] != null) {
            fits = false;
            break;
          }
        }
        if (!fits) offset++;
      } while (!fits);
      selector.offset = offset;
      for (int classId in selector.classIds) {
        int entry = offset + classId;
        while (_table.length <= entry) {
          _table.add(null);
        }
        assert(_table[entry] == null);
        _table[entry] = selector.targets[classId];
      }
      while (firstAvailable < _table.length && _table[firstAvailable] != null) {
        firstAvailable++;
      }
    }

    wasmTable = m.addTable(w.RefType.func(nullable: true), _table.length);
  }

  void output() {
    for (int i = 0; i < _table.length; i++) {
      Reference? target = _table[i];
      if (target != null) {
        w.BaseFunction? fun = translator.functions.getExistingFunction(target);
        if (fun != null) {
          wasmTable.setElement(i, fun);
        }
      }
    }
  }
}
