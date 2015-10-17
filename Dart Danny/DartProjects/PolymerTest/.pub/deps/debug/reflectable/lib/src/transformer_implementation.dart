// (c) 2015, the Dart Team. All rights reserved. Use of this
// source code is governed by a BSD-style license that can be found in
// the LICENSE file.

library reflectable.src.transformer_implementation;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:analyzer/src/generated/ast.dart';
import 'package:analyzer/src/generated/constant.dart';
import 'package:analyzer/src/generated/element.dart';
import 'package:analyzer/src/generated/utilities_dart.dart';
import 'package:barback/barback.dart';
import 'package:code_transformers/resolver.dart';
import 'package:path/path.dart' as path;
import 'element_capability.dart' as ec;
import 'encoding_constants.dart' as constants;
import 'fixed_point.dart';
import 'reflectable_class_constants.dart' as reflectable_class_constants;
import 'transformer_errors.dart' as errors;

// Single source of instances of [Resolver], shared across multiple
// invocations of `apply` to save memory.
Resolvers _resolvers = new Resolvers(dartSdkDirectory);

class ReflectionWorld {
  final Resolver resolver;
  final AssetId generatedLibraryId;
  final List<_ReflectorDomain> reflectors;
  final LibraryElement reflectableLibrary;
  final LibraryElement entryPointLibrary;
  final _ImportCollector importCollector;

  ReflectionWorld(this.resolver, this.generatedLibraryId, this.reflectors,
      this.reflectableLibrary, this.entryPointLibrary, this.importCollector);

  /// Returns code which will create all the data structures (esp. mirrors)
  /// needed to enable the correct behavior for all [reflectors]. The
  /// [resolver] is used to obtain static analysis information about the
  /// entry point for this world, i.e., [entryPointLibrary], the [logger]
  /// is used to report diagnostic messages, and [dataId] specifies the
  /// asset where the generated code will be stored.
  String generateCode(TransformLogger logger) {
    return _formatAsMap(reflectors.map((_ReflectorDomain reflector) {
      String reflectorCode = reflector._generateCode(importCollector, logger);
      return "${reflector._constConstructionCode(importCollector)}: "
          "$reflectorCode";
    }));
  }
}

/// Similar to a `Set<T>` but also keeps track of the index of the first
/// insertion of each item.
class Enumerator<T> {
  final Map<T, int> _map = new Map<T, int>();
  int _count = 0;

  bool _contains(T t) => _map.containsKey(t);

  get length => _count;

  /// Tries to insert [t]. If it was already there return false, else insert it
  /// and return true.
  bool add(T t) {
    if (_contains(t)) return false;
    _map[t] = _count;
    ++_count;
    return true;
  }

  /// Returns the index of a given item.
  int indexOf(T t) {
    return _map[t];
  }

  /// Returns all the items in the order they were inserted.
  Iterable<T> get items {
    return _map.keys;
  }

  /// Clears all elements from this [Enumerator].
  void clear() {
    _map.clear();
    _count = 0;
  }
}

/// Hybrid data structure holding [ClassElement]s and supporting data.
/// It holds three different data structures used to describe the set of
/// classes under transformation. It holds an [Enumerator] named
/// [classElements] which as a set-like data structure that also enables
/// clients to obtain unique indices for each member; it holds a map
/// [elementToDomain] that maps each [ClassElement] to a corresponding
/// [_ClassDomain]; and it holds a relation [mixinApplicationSupers] that
/// maps each [ClassElement] which is a direct subclass of a mixin application
/// to its superclass. The latter is needed because the analyzer representation
/// of mixins and mixin applications makes it difficult to find a superclass
/// which is a mixin application (`ClassElement.supertype` is the _syntactic_
/// superclass, that is, for `class C extends B with M..` it is `B`, not the
/// mixin application `B with M`). The three data structures are bundled
/// together in this class because they must remain consistent and hence all
/// operations on them should be expressed in one location, namely this class.
/// Note that this data structure can delegate all read-only operations to
/// the [classElements], because they will not break consistency, but for every
/// mutating method we need to maintain the invariants.
class ClassElementEnhancedSet implements Set<ClassElement> {
  final _ReflectorDomain reflectorDomain;
  final Enumerator<ClassElement> classElements = new Enumerator<ClassElement>();
  final Map<ClassElement, _ClassDomain> elementToDomain =
      <ClassElement, _ClassDomain>{};
  final Map<ClassElement, MixinApplication> mixinApplicationSupers =
      <ClassElement, MixinApplication>{};

  ClassElementEnhancedSet(this.reflectorDomain);

  @override
  Iterable map(f(ClassElement element)) => classElements.items.map(f);

  @override
  Iterable<ClassElement> where(bool f(ClassElement element)) {
    return classElements.items.where(f);
  }

  @override
  Iterable expand(Iterable f(ClassElement element)) {
    return classElements.items.expand(f);
  }

  @override
  void forEach(void f(ClassElement element)) => classElements.items.forEach(f);

  @override
  ClassElement reduce(
      ClassElement combine(ClassElement value, ClassElement element)) {
    return classElements.items.reduce(combine);
  }

  @override
  dynamic fold(
      initialValue, dynamic combine(previousValue, ClassElement element)) {
    return classElements.items.fold(initialValue, combine);
  }

  @override
  bool every(bool f(ClassElement element)) => classElements.items.every(f);

  @override
  String join([String separator = ""]) => classElements.items.join(separator);

  @override
  bool any(bool f(ClassElement element)) => classElements.items.any(f);

  @override
  List<ClassElement> toList({bool growable: true}) {
    return classElements.items.toList(growable: growable);
  }

  @override
  int get length => classElements.items.length;

  @override
  bool get isEmpty => classElements.items.isEmpty;

  @override
  bool get isNotEmpty => classElements.items.isNotEmpty;

  @override
  Iterable<ClassElement> take(int count) => classElements.items.take(count);

  @override
  Iterable<ClassElement> takeWhile(bool test(ClassElement value)) {
    return classElements.items.takeWhile(test);
  }

  @override
  Iterable<ClassElement> skip(int count) => classElements.items.skip(count);

  @override
  Iterable<ClassElement> skipWhile(bool test(ClassElement value)) {
    return classElements.items.skipWhile(test);
  }

  @override
  ClassElement get first => classElements.items.first;

  @override
  ClassElement get last => classElements.items.last;

  @override
  ClassElement get single => classElements.items.single;

  @override
  ClassElement firstWhere(bool test(ClassElement element),
      {ClassElement orElse()}) {
    return classElements.items.firstWhere(test, orElse: orElse);
  }

  @override
  ClassElement lastWhere(bool test(ClassElement element),
      {ClassElement orElse()}) {
    return classElements.items.lastWhere(test, orElse: orElse);
  }

  @override
  ClassElement singleWhere(bool test(ClassElement element)) {
    return classElements.items.singleWhere(test);
  }

  @override
  ClassElement elementAt(int index) => classElements.items.elementAt(index);

  @override
  Iterator<ClassElement> get iterator => classElements.items.iterator;

  @override
  bool contains(Object value) => classElements.items.contains(value);

  @override
  bool add(ClassElement value) {
    bool result = classElements.add(value);
    if (result) {
      assert(!elementToDomain.containsKey(value));
      elementToDomain[value] = _createClassDomain(value, reflectorDomain);
      if (value is MixinApplication && value.subclass != null) {
        // [value] is a mixin application which is the immediate superclass
        // of a class which is a regular class (not a mixin application). This
        // means that we must store it in `mixinApplicationSupers` such that
        // we can look it up during invocations of [superclassOf].
        assert(!mixinApplicationSupers.containsKey(value.subclass));
        mixinApplicationSupers[value.subclass] = value;
      }
    }
    return result;
  }

  @override
  void addAll(Iterable<ClassElement> elements) => elements.forEach(add);

  @override
  bool remove(Object value) {
    bool result = classElements._contains(value);
    classElements._map.remove(value);
    if (result) {
      assert(elementToDomain.containsKey(value));
      elementToDomain.remove(value);
      if (value is MixinApplication && value.subclass != null) {
        // [value] must have been stored in `mixinApplicationSupers`,
        // so for consistency we must remove it from there, too.
        assert(mixinApplicationSupers.containsKey(value.subclass));
        mixinApplicationSupers.remove(value.subclass);
      }
    }
    return result;
  }

  @override
  ClassElement lookup(Object object) {
    for (ClassElement classElement in classElements._map.keys) {
      if (object == classElement) return classElement;
    }
    return null;
  }

  @override
  void removeAll(Iterable<Object> elements) => elements.forEach(remove);

  @override
  void retainAll(Iterable<Object> elements) {
    bool test(ClassElement element) => !elements.contains(element);
    removeWhere(test);
  }

  @override
  void removeWhere(bool test(ClassElement element)) {
    Set<ClassElement> toRemove = new Set<ClassElement>();
    for (ClassElement classElement in classElements.items) {
      if (test(classElement)) toRemove.add(classElement);
    }
    removeAll(toRemove);
  }

  @override
  void retainWhere(bool test(ClassElement element)) {
    bool inverted_test(ClassElement element) => !test(element);
    removeWhere(inverted_test);
  }

  @override
  bool containsAll(Iterable<Object> other) {
    return classElements.items.toSet().containsAll(other);
  }

  @override
  Set<ClassElement> intersection(Set<Object> other) {
    return classElements.items.toSet().intersection(other);
  }

  @override
  Set<ClassElement> union(Set<ClassElement> other) {
    return classElements.items.toSet().union(other);
  }

  @override
  Set<ClassElement> difference(Set<ClassElement> other) {
    return classElements.items.toSet().difference(other);
  }

  @override
  void clear() {
    classElements.clear();
    elementToDomain.clear();
  }

  @override
  Set<ClassElement> toSet() => this;

  /// Returns the superclass of the given [classElement] using the language
  /// semantics rather than the analyzer model (where the superclass is the
  /// syntactic one, i.e., `class C extends B with M..` has superclass `B`,
  /// not the mixin application `B with M`). This method will use the analyzer
  /// data to find the superclass, which means that it will _not_ refrain
  /// from returning a class which is not covered by any particular reflector.
  /// It is up to the caller to check that.
  ClassElement superclassOf(ClassElement classElement) {
    // By construction of [MixinApplication]s, their `superclass` is correct.
    if (classElement is MixinApplication) return classElement.superclass;
    // For a regular class whose superclass is also not a mixin application,
    // the analyzer `supertype` is what we want. Note that this gets [null]
    // from [Object], which is intended: We consider that (non-existing) class
    // as covered, and use [null] to represent it; there is no clash with
    // returning [null] to indicate that a superclass is not covered, because
    // this method does not check coverage.
    if (classElement.mixins.isEmpty) return classElement.supertype?.element;
    // [classElement] is now known to be a regular class whose superclass
    // is a mixin application. For each [MixinApplication] `m` we store, if it
    // was created as a superclass of a regular (non mixin application) class
    // `C` then we have stored a mapping from `C` to `m` in the map
    // `mixinApplicationSupers`.
    assert(mixinApplicationSupers.containsKey(classElement));
    return mixinApplicationSupers[classElement];
  }

  /// Returns the _ClassDomain corresponding to the given [classElement],
  /// which must be a member of this [ClassElementEnhancedSet].
  _ClassDomain domainOf(ClassElement classElement) {
    assert(elementToDomain.containsKey(classElement));
    return elementToDomain[classElement];
  }

  /// Returns the index of the given [classElement] if it is contained
  /// in this [ClassElementEnhancedSet], otherwise [null].
  int indexOf(ClassElement classElement) {
    return classElements.indexOf(classElement);
  }

  Iterable<_ClassDomain> get domains => elementToDomain.values;
}

/// Information about the program parts that can be reflected by a given
/// Reflector.
class _ReflectorDomain {
  final Resolver _resolver;
  final AssetId _generatedLibraryId;
  final ClassElement _reflector;

  /// Do not use this, use [classes] which ensures that closures operations
  /// have been performed as requested in [_capabilities]. Exception: In
  /// `_computeWorld`, [_classes] is filled in with the set of directly
  /// covered classes during creation of this [_ReflectorDomain].
  /// NB: [_classes] should be final, but it is not possible because this
  /// would create a cycle of final fields, which cannot be initialized.
  ClassElementEnhancedSet _classes;

  /// Used by [classes], only, to keep track of whether [_classes] has been
  /// properly initialized by means of closure operations.
  bool _classesInitialized = false;

  /// Returns the set of classes covered by `_reflector`, including the ones
  /// which are directly covered by carrying `_reflector` as metadata or being
  /// matched by a global quantifier, and including the ones which are reached
  /// via the closure operations requested in [_capabilities].
  ClassElementEnhancedSet get classes {
    if (!_classesInitialized) {
      if (_capabilities._impliesDownwardsClosure) {
        new _SubtypesFixedPoint(_resolver).expand(_classes);
      }
      if (_capabilities._impliesUpwardsClosure) {
        new _SuperclassFixedPoint(_capabilities._upwardsClosureBounds,
            _capabilities._impliesMixins).expand(_classes);
      } else {
        // Even without an upwards closure we cover some superclasses, namely
        // mixin applications where the class applied as a mixin is covered (it
        // seems natural to cover applications of covered mixins and there is
        // no other way to request that, other than requesting a full upwards
        // closure which might add many more classes).
        _mixinApplicationsOfClasses(_classes).forEach(_classes.add);
      }
      if (_capabilities._impliesTypes &&
          _capabilities._impliesTypeAnnotations) {
        _AnnotationClassFixedPoint fix = new _AnnotationClassFixedPoint(
            _resolver, _generatedLibraryId, _classes.domainOf);
        if (_capabilities._impliesTypeAnnotationClosure) {
          fix.expand(_classes);
        } else {
          fix.singleExpand(_classes);
        }
      }
      _classesInitialized = true;
    }
    return _classes;
  }

  final Set<LibraryElement> _libraries = new Set<LibraryElement>();

  final _Capabilities _capabilities;

  _ReflectorDomain(this._resolver, this._generatedLibraryId, this._reflector,
      this._capabilities) {
    _classes = new ClassElementEnhancedSet(this);
  }

  // TODO(eernst) future: Perhaps reconsider what the best strategy
  // for caching is.
  Map<ClassElement, Map<String, ExecutableElement>> _instanceMemberCache =
      new Map<ClassElement, Map<String, ExecutableElement>>();

  /// Returns a string that evaluates to a closure invoking [constructor] with
  /// the given arguments.
  /// [importCollector] is used to record all the imports needed to make the
  /// constant.
  /// This is to provide something that can be called with [Function.apply].
  ///
  /// For example for a constructor Foo(x, {y: 3}):
  /// returns "(x, {y: 3}) => new prefix1.Foo(x, y)", and records an import of
  /// the library of `Foo` associated with prefix1 in [importCollector].
  String _constructorCode(ConstructorElement constructor,
      _ImportCollector importCollector, TransformLogger logger) {
    FunctionType type = constructor.type;

    int requiredPositionalCount = type.normalParameterTypes.length;
    int optionalPositionalCount = type.optionalParameterTypes.length;

    List<String> parameterNames = type.parameters
        .map((ParameterElement parameter) => parameter.name)
        .toList();

    List<String> namedParameterNames = type.namedParameterTypes.keys.toList();

    String positionals = new Iterable.generate(
        requiredPositionalCount, (int i) => parameterNames[i]).join(", ");

    String optionalsWithDefaults =
        new Iterable.generate(optionalPositionalCount, (int i) {
      ParameterElement parameterElement =
          constructor.parameters[requiredPositionalCount + i];
      FormalParameter parameterNode = parameterElement.computeNode();
      String defaultValueCode = "";
      if (parameterNode is DefaultFormalParameter &&
          parameterNode.defaultValue != null) {
        defaultValueCode = " = ${_extractConstantCode(
            parameterNode.defaultValue,
            parameterElement.library,
            importCollector, logger, _generatedLibraryId, _resolver)}";
      }
      return "${parameterNames[requiredPositionalCount + i]}"
          "$defaultValueCode";
    }).join(", ");

    String namedWithDefaults =
        new Iterable.generate(namedParameterNames.length, (int i) {
      // Note that the use of `requiredPositionalCount + i` below relies
      // on a language design where no parameter list can include
      // both optional positional and named parameters, so if there are
      // any named parameters then all optional parameters are named.
      ParameterElement parameterElement =
          constructor.parameters[requiredPositionalCount + i];
      FormalParameter parameterNode = parameterElement.computeNode();
      String defaultValueCode = "";
      if (parameterNode is DefaultFormalParameter &&
          parameterNode.defaultValue != null) {
        defaultValueCode = ": ${_extractConstantCode(
            parameterNode.defaultValue,
            parameterElement.library,
            importCollector, logger, _generatedLibraryId, _resolver)}";
      }
      return "${namedParameterNames[i]}$defaultValueCode";
    }).join(", ");

    String optionalArguments = new Iterable.generate(optionalPositionalCount,
        (int i) => parameterNames[i + requiredPositionalCount]).join(", ");
    String namedArguments =
        namedParameterNames.map((String name) => "$name: $name").join(", ");

    List<String> parameterParts = new List<String>();
    List<String> argumentParts = new List<String>();

    if (requiredPositionalCount != 0) {
      parameterParts.add(positionals);
      argumentParts.add(positionals);
    }
    if (optionalPositionalCount != 0) {
      parameterParts.add("[$optionalsWithDefaults]");
      argumentParts.add(optionalArguments);
    }
    if (namedParameterNames.isNotEmpty) {
      parameterParts.add("{${namedWithDefaults}}");
      argumentParts.add(namedArguments);
    }

    String prefix = importCollector._getPrefix(constructor.library);
    return ('(${parameterParts.join(', ')}) => '
        'new $prefix.${_nameOfDeclaration(constructor)}'
        '(${argumentParts.join(", ")})');
  }

  /// The code of the const-construction of this reflector.
  String _constConstructionCode(_ImportCollector importCollector) {
    String prefix = importCollector._getPrefix(_reflector.library);
    return "const $prefix.${_reflector.name}()";
  }

  /// Generate the code which will create a `ReflectorData` instance
  /// containing the mirrors and other reflection data which is needed for
  /// `_reflector` to behave correctly.
  String _generateCode(
      _ImportCollector importCollector, TransformLogger logger) {
    Enumerator<ExecutableElement> members = new Enumerator<ExecutableElement>();
    Enumerator<FieldElement> fields = new Enumerator<FieldElement>();
    Enumerator<ParameterElement> parameters =
        new Enumerator<ParameterElement>();
    Enumerator<LibraryElement> libraries = new Enumerator<LibraryElement>();
    Set<String> instanceGetterNames = new Set<String>();
    Set<String> instanceSetterNames = new Set<String>();

    // Fill in [libraries], [members], [fields], [parameters],
    // [instanceGetterNames], and [instanceSetterNames].
    for (LibraryElement library in _libraries) {
      libraries.add(library);
    }
    for (_ClassDomain classDomain in classes.domains) {
      // Gather the behavioral interface into [members]. Note that
      // this includes implicitly generated getters and setters, but
      // omits fields. Also note that this does not match the
      // semantics of the `declarations` method in a [ClassMirror].
      classDomain._declarations.forEach(members.add);

      // Add the behavioral interface from this class (redundantly, for
      // non-static members) and all superclasses (which matters) to
      // [members], such that it contains both the behavioral parts for
      // the target class and its superclasses, and the program structure
      // oriented parts for the target class (omitting those from its
      // superclasses).
      classDomain._instanceMembers.forEach(members.add);

      // Add all the formal parameters (as a single, global set) which
      // are declared by any of the methods in `classDomain._declarations`
      // as well as in `classDomain._instanceMembers`.
      classDomain._declaredParameters.forEach(parameters.add);
      classDomain._instanceParameters.forEach(parameters.add);

      // Gather the fields declared in the target class (not inherited
      // ones) in [fields], i.e., the elements missing from [members]
      // at this point, in order to support `declarations` in a
      // [ClassMirror].
      classDomain._declaredFields.forEach(fields.add);

      // Gather all getter and setter names based on [instanceMembers],
      // including both explicitly declared ones, implicitly generated ones
      // for fields, and the implicitly generated ones that correspond to
      // method tear-offs.
      classDomain._instanceMembers.forEach((ExecutableElement instanceMember) {
        if (instanceMember is PropertyAccessorElement) {
          // A getter or a setter, synthetic or declared.
          if (instanceMember.isGetter) {
            instanceGetterNames.add(instanceMember.name);
          } else {
            instanceSetterNames.add(instanceMember.name);
          }
        } else if (instanceMember is MethodElement) {
          instanceGetterNames.add(instanceMember.name);
        } else {
          // `instanceMember` is a ConstructorElement.
          // Even though a generative constructor has a false
          // `isStatic`, we do not wish to include them among
          // instanceGetterNames, so we do nothing here.
        }
      });
    }

    // Generate code for creation of class mirrors.
    String classMirrorsCode = _formatAsList(
        "m.ClassMirror",
        _capabilities._impliesTypes
            ? classes.domains.map((_ClassDomain classDomain) =>
                _classMirrorCode(classDomain, fields, members, libraries,
                    importCollector, logger))
            : <String>[]);

    // Generate code for creation of getter and setter closures.
    String gettersCode = _formatAsMap(instanceGetterNames.map(_gettingClosure));
    String settersCode = _formatAsMap(instanceSetterNames.map(_settingClosure));

    // Generate code for creation of member mirrors.
    Iterable<String> methodsList =
        members.items.map((ExecutableElement executableElement) {
      return _methodMirrorCode(executableElement, fields, members, parameters,
          importCollector, logger);
    });
    Iterable<String> fieldsList = fields.items.map((FieldElement element) {
      return _fieldMirrorCode(element, importCollector, logger);
    });
    List<String> membersList = <String>[]
      ..addAll(fieldsList)
      ..addAll(methodsList);
    String membersCode = _formatAsList("m.DeclarationMirror", membersList);

    // Generate code for listing [Type] instances.
    String typesCode =
        _formatAsList("Type", classes.map((ClassElement classElement) {
      return _typeCode(classElement, importCollector);
    }));

    // Generate code for creation of library mirrors.
    String librariesCode;
    if (!_capabilities.supportsLibraries) {
      librariesCode = "null";
    } else {
      librariesCode = _formatAsList("m.LibraryMirror",
          libraries.items.map((LibraryElement library) {
        return _libraryMirrorCode(library, importCollector, logger);
      }));
    }

    // Generate code for creation of parameter mirrors.
    Iterable<String> parametersList =
        parameters.items.map((ParameterElement element) {
      return _parameterMirrorCode(
          element, fields, members, importCollector, logger);
    });
    String parameterMirrorsCode =
        _formatAsList("m.ParameterMirror", parametersList);

    return "new r.ReflectorData($classMirrorsCode, $membersCode, "
        "$parameterMirrorsCode, $typesCode, $gettersCode, $settersCode, "
        "$librariesCode)";
  }

  int _computeTypeIndexBase(
      Element typeElement, bool isVoid, bool isDynamic, bool isClassType) {
    if (_capabilities._impliesTypes) {
      if (isDynamic || isVoid) {
        // The mirror will report 'dynamic' or 'void' as its `returnType`
        // and it will never use the index.
        return null;
      }
      if (isClassType) {
        // Normal encoding of a class type. That class has been added
        // to `classes`, so the `indexOf` cannot return `null`.
        assert(classes.contains(typeElement));
        return classes.indexOf(typeElement);
      }
    }
    return constants.NO_CAPABILITY_INDEX;
  }

  int _computeFieldTypeIndex(FieldElement element, int descriptor) {
    if (!_capabilities._impliesTypes) return constants.NO_CAPABILITY_INDEX;
    return _computeTypeIndexBase(
        element.type.element,
        false, // No field has type `void`.
        descriptor & constants.dynamicAttribute != 0,
        descriptor & constants.classTypeAttribute != 0);
  }

  int _computeReturnTypeIndex(ExecutableElement element, int descriptor) {
    if (!_capabilities._impliesTypes) return constants.NO_CAPABILITY_INDEX;
    int result = _computeTypeIndexBase(
        element.returnType.element,
        descriptor & constants.voidReturnTypeAttribute != 0,
        descriptor & constants.dynamicReturnTypeAttribute != 0,
        descriptor & constants.classReturnTypeAttribute != 0);
    return result;
  }

  Iterable<PropertyAccessorElement> _gettersOfLibrary(LibraryElement library) {
    return library.units.map((CompilationUnitElement part) {
      Iterable<Element> getters = <Iterable<Element>>[
        part.accessors
            .where((PropertyAccessorElement accessor) => accessor.isGetter),
        part.functions,
        part.topLevelVariables
      ].expand((Iterable<Element> elements) => elements);
      return getters.where((Element getter) =>
          _capabilities.supportsTopLevelInvoke(getter.name, getter.metadata));
    }).expand((Iterable<Element> x) => x);
  }

  Iterable<PropertyAccessorElement> _settersOfLibrary(LibraryElement library) {
    return library.units.map((CompilationUnitElement part) {
      Iterable setters = <Iterable<Element>>[
        part.accessors
            .where((PropertyAccessorElement accessor) => accessor.isSetter),
        part.topLevelVariables
            .where((TopLevelVariableElement variable) => !variable.isFinal)
      ].expand((Iterable<Element> elements) => elements);
      return setters.where((Element setter) =>
          _capabilities.supportsTopLevelInvoke(setter.name, setter.metadata));
    }).expand((Iterable<Element> x) => x);
  }

  String _classMirrorCode(
      _ClassDomain classDomain,
      Enumerator<FieldElement> fields,
      Enumerator<ExecutableElement> members,
      Enumerator<LibraryElement> libraries,
      _ImportCollector importCollector,
      TransformLogger logger) {
    // Fields go first in [memberMirrors], so they will get the
    // same index as in [fields].
    Iterable<int> fieldsIndices =
        classDomain._declaredFields.map((FieldElement element) {
      return fields.indexOf(element);
    });

    // All the elements in the behavioral interface go after the
    // fields in [memberMirrors], so they must get an offset of
    // `fields.length` on the index.
    Iterable<int> methodsIndices = classDomain._declarations
        .where(_executableIsntImplicitGetterOrSetter)
        .map((ExecutableElement element) {
      // TODO(eernst) implement: The "magic" default constructor in `Object`
      // (the one that ultimately allocates the memory for _every_ new
      // object) has no index, which creates the need to catch a `null`
      // here. Search for "magic" to find other occurrences of the same
      // issue. For now, we use the index [constants.NO_CAPABILITY_INDEX]
      // for this declaration, because it is not yet supported.
      // Need to find the correct solution, though!
      int index = members.indexOf(element);
      return index == null
          ? constants.NO_CAPABILITY_INDEX
          : index + fields.length;
    });

    String declarationsCode = "<int>[${constants
        .NO_CAPABILITY_INDEX}]";
    if (_capabilities._impliesDeclarations) {
      List<int> declarationsIndices = <int>[]
        ..addAll(fieldsIndices)
        ..addAll(methodsIndices);
      declarationsCode = _formatAsList("int", declarationsIndices);
    }

    // All instance members belong to the behavioral interface, so they
    // also get an offset of `fields.length`.
    String instanceMembersCode = _formatAsList("int",
        classDomain._instanceMembers.map((ExecutableElement element) {
      // TODO(eernst) implement: The "magic" default constructor has
      // index: NO_CAPABILITY_INDEX; adjust this when support for it has
      // been implemented.
      int index = members.indexOf(element);
      return index == null
          ? constants.NO_CAPABILITY_INDEX
          : index + fields.length;
    }));

    // All static members belong to the behavioral interface, so they
    // also get an offset of `fields.length`.
    String staticMembersCode = _formatAsList("int",
        classDomain._staticMembers.map((ExecutableElement element) {
      int index = members.indexOf(element);
      return index == null
          ? constants.NO_CAPABILITY_INDEX
          : index + fields.length;
    }));

    ClassElement classElement = classDomain._classElement;
    ClassElement superclass = classes.superclassOf(classElement);
    // [Object]'s superclass is reported as `null`: it does not exist and
    // hence we cannot decide whether it's supported or unsupported; by
    // convention we make it supported and report it in the same way as
    // 'dart:mirrors'. Other superclasses use `NO_CAPABILITY_INDEX` to
    // indicate missing support.
    String superclassIndex = classElement.type.isObject
        ? "null"
        : (classes.contains(superclass))
            ? "${classes.indexOf(superclass)}"
            : "${constants.NO_CAPABILITY_INDEX}";

    String constructorsCode;
    if (classElement is MixinApplication || classElement.isAbstract) {
      constructorsCode = '{}';
    } else {
      constructorsCode = _formatAsMap(
          classDomain._constructors.map((ConstructorElement constructor) {
        String code = _constructorCode(constructor, importCollector, logger);
        return 'r"${constructor.name}": $code';
      }));
    }

    String staticGettersCode = "{}";
    String staticSettersCode = "{}";
    if (classElement is! MixinApplication) {
      staticGettersCode = _formatAsMap([
        classDomain._declaredMethods
            .where((ExecutableElement element) => element.isStatic),
        classDomain._declaredAndImplicitAccessors.where(
            (PropertyAccessorElement element) =>
                element.isStatic && element.isGetter)
      ].expand((x) => x).map((ExecutableElement element) =>
          _staticGettingClosure(importCollector, classElement, element.name)));
      staticSettersCode = _formatAsMap(classDomain._declaredAndImplicitAccessors
          .where((PropertyAccessorElement element) =>
              element.isStatic && element.isSetter)
          .map((PropertyAccessorElement element) => _staticSettingClosure(
              importCollector, classElement, element.name)));
    }

    int mixinIndex;
    if (classElement.isMixinApplication) {
      // Named mixin application (using the syntax `class B = A with M;`).
      mixinIndex = classes.indexOf(classElement.mixins.last.element);
    } else {
      mixinIndex = (classElement is MixinApplication)
          ? classes.indexOf(classElement.mixin)
          : classes.indexOf(classElement);
    }
    if (mixinIndex == null) mixinIndex = constants.NO_CAPABILITY_INDEX;

    int ownerIndex = _capabilities.supportsLibraries
        ? libraries.indexOf(classElement.library)
        : constants.NO_CAPABILITY_INDEX;

    String superinterfaceIndices = _formatAsList(
        'int',
        classElement.interfaces
            .map((InterfaceType type) => type.element)
            .where(classes.contains)
            .map(classes.indexOf));

    String classMetadataCode;
    if (_capabilities._supportsMetadata) {
      classMetadataCode = _extractMetadataCode(classElement, _resolver,
          importCollector, logger, _generatedLibraryId);
    } else {
      classMetadataCode = "null";
    }

    int classIndex = classes.indexOf(classElement);

    String result = 'new r.ClassMirrorImpl(r"${classDomain._simpleName}", '
        'r"${_qualifiedName(classElement)}", $classIndex, '
        '${_constConstructionCode(importCollector)}, '
        '$declarationsCode, $instanceMembersCode, $staticMembersCode, '
        '$superclassIndex, $staticGettersCode, $staticSettersCode, '
        '$constructorsCode, $ownerIndex, $mixinIndex, '
        '$superinterfaceIndices, $classMetadataCode)';
    return result;
  }

  String _methodMirrorCode(
      ExecutableElement element,
      Enumerator<FieldElement> fields,
      Enumerator<ExecutableElement> members,
      Enumerator<ParameterElement> parameters,
      _ImportCollector importCollector,
      TransformLogger logger) {
    if (element is PropertyAccessorElement && element.isSynthetic) {
      // There is no type propagation, so we declare an `accessorElement`.
      PropertyAccessorElement accessorElement = element;
      int variableMirrorIndex = fields.indexOf(accessorElement.variable);
      // The `indexOf` is non-null: `accessorElement` came from `members`.
      int selfIndex = members.indexOf(accessorElement) + fields.length;
      if (accessorElement.isGetter) {
        return 'new r.ImplicitGetterMirrorImpl('
            '${_constConstructionCode(importCollector)}, '
            '$variableMirrorIndex, $selfIndex)';
      } else {
        assert(accessorElement.isSetter);
        return 'new r.ImplicitSetterMirrorImpl('
            '${_constConstructionCode(importCollector)}, '
            '$variableMirrorIndex, $selfIndex)';
      }
    } else {
      int descriptor = _declarationDescriptor(element);
      int returnTypeIndex = _computeReturnTypeIndex(element, descriptor);
      int ownerIndex = classes.indexOf(element.enclosingElement);
      String parameterIndicesCode = _formatAsList("int",
          element.parameters.map((ParameterElement parameterElement) {
        return parameters.indexOf(parameterElement);
      }));
      String metadataCode = _capabilities._supportsMetadata
          ? _extractMetadataCode(
              element, _resolver, importCollector, logger, _generatedLibraryId)
          : null;
      return 'new r.MethodMirrorImpl(r"${element.name}", $descriptor, '
          '$ownerIndex, $returnTypeIndex, $parameterIndicesCode, '
          '${_constConstructionCode(importCollector)}, $metadataCode)';
    }
  }

  String _fieldMirrorCode(FieldElement element,
      _ImportCollector importCollector, TransformLogger logger) {
    int descriptor = _fieldDescriptor(element);
    int ownerIndex = classes.indexOf(element.enclosingElement);
    int classMirrorIndex = _computeFieldTypeIndex(element, descriptor);
    String metadataCode;
    if (_capabilities._supportsMetadata) {
      metadataCode = _extractMetadataCode(
          element, _resolver, importCollector, logger, _generatedLibraryId);
    } else {
      // We encode 'without capability' as `null` for metadata, because
      // it is a `List<Object>`, which has no other natural encoding.
      metadataCode = null;
    }
    return 'new r.VariableMirrorImpl(r"${element.name}", $descriptor, '
        '$ownerIndex, ${_constConstructionCode(importCollector)}, '
        '$classMirrorIndex, $metadataCode)';
  }

  String _typeCode(
      ClassElement classElement, _ImportCollector importCollector) {
    if (classElement is MixinApplication && classElement.declaredName == null) {
      return 'new r.FakeType(r"${classElement.name}")';
    }
    String prefix = importCollector._getPrefix(classElement.library);
    return "$prefix.${classElement.name}";
  }

  String _libraryMirrorCode(LibraryElement library,
      _ImportCollector importCollector, TransformLogger logger) {
    String gettersCode = _formatAsMap(
        _gettersOfLibrary(library).map((PropertyAccessorElement getter) {
      return _topLevelGettingClosure(importCollector, library, getter.name);
    }));
    String settersCode = _formatAsMap(
        _settersOfLibrary(library).map((PropertyAccessorElement setter) {
      return topLevelSettingClosure(importCollector, library, setter.name);
    }));

    // TODO(sigurdm) clarify: Find out how to get good uri's in a
    // transformer.
    // TODO(sigurdm) implement: Check for `uriCapability`.
    String uriCode = "null";

    String metadataCode;
    if (_capabilities._supportsMetadata) {
      metadataCode = _extractMetadataCode(
          library, _resolver, importCollector, logger, _generatedLibraryId);
    } else {
      metadataCode = "null";
    }

    return 'new r.LibraryMirrorImpl(r"${library.name}", $uriCode, '
        '$gettersCode, $settersCode, $metadataCode)';
  }

  String _parameterMirrorCode(
      ParameterElement element,
      Enumerator<FieldElement> fields,
      Enumerator<ExecutableElement> members,
      _ImportCollector importCollector,
      TransformLogger logger) {
    int descriptor = _parameterDescriptor(element);
    int ownerIndex = members.indexOf(element.enclosingElement) + fields.length;
    int classMirrorIndex;
    if (_capabilities._impliesTypes) {
      if (descriptor & constants.dynamicAttribute != 0) {
        // This parameter will report its type as `dynamic`, and it
        // will never use `classMirrorIndex`.
        classMirrorIndex = null;
      } else if (descriptor & constants.classTypeAttribute != 0) {
        // Normal encoding of a class type. That class has been added
        // to `classes`, so the `indexOf` cannot return `null`.
        assert(classes.contains(element.type.element));
        classMirrorIndex = classes.indexOf(element.type.element);
      }
    } else {
      classMirrorIndex = constants.NO_CAPABILITY_INDEX;
    }
    String metadataCode = "null";
    if (_capabilities._supportsMetadata) {
      FormalParameter node = element.computeNode();
      if (node == null) {
        metadataCode = "<Object>[]";
      } else {
        NodeList<Annotation> annotations = node.metadata;
        metadataCode =
            _formatAsList("Object", annotations.map((Annotation annotation) {
          return _extractAnnotationValue(
              annotation, element.library, importCollector);
        }));
      }
    }
    FormalParameter parameterNode = element.computeNode();
    String defaultValueCode = "null";
    if (parameterNode is DefaultFormalParameter &&
        parameterNode.defaultValue != null) {
      defaultValueCode = _extractConstantCode(
          parameterNode.defaultValue,
          element.library,
          importCollector,
          logger,
          _generatedLibraryId,
          _resolver);
    }
    return 'new r.ParameterMirrorImpl(r"${element.name}", $descriptor, '
        '$ownerIndex, ${_constConstructionCode(importCollector)}, '
        '$classMirrorIndex, $metadataCode, $defaultValueCode)';
  }
}

/// Auxiliary class used by `classes`. Its `expand` method expands
/// its argument to a fixed point, based on the `successors` method.
class _SubtypesFixedPoint extends FixedPoint<ClassElement> {
  final Resolver resolver;

  /// The inverse relation of `superinterfaces`, globally.
  final Map<ClassElement, Set<ClassElement>> subtypes =
      <ClassElement, Set<ClassElement>>{};

  _SubtypesFixedPoint(this.resolver) {
    // Initialize `subtypes`.
    for (LibraryElement library in resolver.libraries) {
      for (CompilationUnitElement unit in library.units) {
        for (ClassElement classElement in unit.types) {
          InterfaceType supertype = classElement.type.superclass;
          if (classElement.mixins.isEmpty) {
            if (supertype?.element != null) {
              _addSubtypeRelation(supertype.element, classElement);
            }
          } else {
            // Mixins must be applied to a superclass, so it is not null.
            ClassElement superclass = supertype.element;
            // Iterate over all mixins in most-general-first order (so with
            // `class C extends B with M1, M2..` we visit `M1` then `M2`.
            for (InterfaceType mixin in classElement.mixins) {
              ClassElement mixinElement = mixin.element;
              ClassElement subClass =
                  mixin == classElement.mixins.last ? classElement : null;
              String name = subClass == null
                  ? null
                  : (classElement.isMixinApplication
                      ? classElement.name
                      : null);
              MixinApplication mixinApplication = new MixinApplication(
                  name, superclass, mixinElement, library, subClass);
              _addSubtypeRelation(superclass, mixinApplication);
              _addSubtypeRelation(mixinElement, mixinApplication);
              if (subClass != null) {
                _addSubtypeRelation(mixinApplication, subClass);
              }
              superclass = mixinApplication;
            }
          }
          for (InterfaceType type in classElement.interfaces) {
            if (type.element != null) {
              _addSubtypeRelation(type.element, classElement);
            }
          }
        }
      }
    }
  }

  _addSubtypeRelation(ClassElement supertype, ClassElement subtype) {
    Set<ClassElement> subtypesOfSupertype = subtypes[supertype];
    if (subtypesOfSupertype == null) {
      subtypesOfSupertype = new Set<ClassElement>();
      subtypes[supertype] = subtypesOfSupertype;
    }
    subtypesOfSupertype.add(subtype);
  }

  /// Returns all the immediate subtypes of the given [classMirror].
  Iterable<ClassElement> successors(final ClassElement classElement) {
    return subtypes[classElement] ?? <ClassElement>[];
  }
}

/// Auxiliary class used by `classes`. Its `expand` method expands
/// its argument to a fixed point, based on the `successors` method.
class _SuperclassFixedPoint extends FixedPoint<ClassElement> {
  final Map<ClassElement, bool> upwardsClosureBounds;
  final bool mixinsRequested;

  _SuperclassFixedPoint(this.upwardsClosureBounds, this.mixinsRequested);

  /// Returns the direct superclass of [element] if it satisfies the given
  /// bounds: If there are any elements in [upwardsClosureBounds] only
  /// classes which are subclasses of an upper bound specified there are
  /// returned (for each bound, if it maps to true then `excludeUpperBound`
  /// was specified, in which case only proper subclasses are returned).
  /// If [mixinsRequested], when considering a superclass which was created as
  /// a mixin application, the class which was applied as a mixin
  /// is also returned (without consulting [upwardsClosureBounds], because a
  /// class used as a mixin cannot have other superclasses than [Object]).
  /// TODO(eernst) implement: When mixins can have nontrivial superclasses
  /// we may or may not wish to enforce the bounds even for mixins.
  Iterable<ClassElement> successors(ClassElement element) sync* {
    // A mixin application is handled by its regular subclasses.
    if (element is MixinApplication) return;
    // If upper bounds not satisfied then there are no successors.
    if (!_includedByUpwardsClosure(element)) return;

    InterfaceType workingSuperType = element.supertype;
    if (workingSuperType == null) return; // "Superclass of [Object]", ignore.
    ClassElement workingSuperclass = workingSuperType.element;

    if (_includedByUpwardsClosure(workingSuperclass)) yield workingSuperclass;

    // Create the chain of mixin applications between [classElement] and the
    // next non-mixin-application class that it extends. If [mixinsRequested]
    // then for each mixin application add the class [mixinClass] which was
    // applied as a mixin (it is then considered as yet another superclass).
    // Note that we iterate from the most general to more special mixins,
    // that is, for `class C extends B with M1, M2..` we visit `M1` before
    // `M2`, which makes the right `superclass` available at each step. We
    // must provide the immediate subclass of each [MixinApplication] when
    // is a regular class (not a mixin application), otherwise [null], which
    // is done with [subClass].
    ClassElement superclass = workingSuperclass;
    for (InterfaceType mixin in element.mixins) {
      ClassElement mixinClass = mixin.element;
      if (mixinsRequested) yield mixinClass;
      ClassElement subClass = mixin == element.mixins.last ? element : null;
      String name = subClass == null
          ? null
          : (element.isMixinApplication ? element.name : null);
      ClassElement mixinApplication = new MixinApplication(
          name, superclass, mixinClass, element.library, subClass);
      // We have already ensured that `workingSuperclass` is a
      // subclass of a bound (if any); the value of `superclass` is
      // either `workingSuperclass` or one of its superclasses created
      // by mixin application. Since there is no way to denote these
      // mixin applications directly, they must also be subclasses
      // of a bound, so these mixin applications must be added
      // unconditionally.
      yield mixinApplication;
      superclass = mixinApplication;
    }
  }

  bool _includedByUpwardsClosure(ClassElement classElement) {
    bool helper(ClassElement classElement, bool direct) {
      bool isSuperclassOfClassElement(ClassElement bound) {
        if (classElement == bound) {
          // If `!direct` then the desired subclass relation exists.
          // If `direct` then the original `classElement` is equal to
          // `bound`, so we must return false if `excludeUpperBound`.
          return !direct || !upwardsClosureBounds[bound];
        }
        if (classElement.supertype == null) return false;
        return helper(classElement.supertype.element, false);
      }
      return upwardsClosureBounds.keys.any(isSuperclassOfClassElement);
    }
    return upwardsClosureBounds.isEmpty || helper(classElement, true);
  }
}

/// Auxiliary function used by `classes`. Its `expand` method
/// expands its argument to a fixed point, based on the `successors` method.
Set<ClassElement> _mixinApplicationsOfClasses(Set<ClassElement> classes) {
  Set<ClassElement> mixinApplications = new Set<ClassElement>();
  for (ClassElement classElement in classes) {
    // Mixin-applications are handled when they are created.
    if (classElement is MixinApplication) continue;
    InterfaceType supertype = classElement.supertype;
    if (supertype == null) continue; // "Superclass of [Object]", ignore.
    ClassElement superclass = supertype.element;
    // Note that we iterate from the most general mixin to more specific ones,
    // that is, with `class C extends B with M1, M2..` we visit `M1` before
    // `M2`; this ensures that the right `superclass` is available for each
    // new [MixinApplication] created.  We must provide the immediate subclass
    // of each [MixinApplication] when it is a regular class (not a mixin
    // application), otherwise [null], which is done with [subClass].
    classElement.mixins.forEach((InterfaceType mixin) {
      ClassElement mixinClass = mixin.element;
      ClassElement subClass =
          mixin == classElement.mixins.last ? classElement : null;
      String name = subClass == null
          ? null
          : (classElement.isMixinApplication ? classElement.name : null);
      ClassElement mixinApplication = new MixinApplication(
          name, superclass, mixinClass, classElement.library, subClass);
      if (classes.contains(mixinClass)) mixinApplications.add(mixinApplication);
      superclass = mixinApplication;
    });
  }
  return mixinApplications;
}

/// Auxiliary type used by [_AnnotationClassFixedPoint].
typedef _ClassDomain ElementToDomain(ClassElement _);

/// Auxiliary class used by `classes`. Its `expand` method
/// expands its argument to a fixed point, based on the `successors` method.
/// It uses [resolver] in a check for "importability" of some private core
/// classes (that we must avoid attempting to use because they are unavailable
/// to user programs). [generatedLibraryId] must refer to the asset where the
/// generated code will be stored; it is used in the same check.
class _AnnotationClassFixedPoint extends FixedPoint<ClassElement> {
  final Resolver resolver;
  final AssetId generatedLibraryId;
  final ElementToDomain elementToDomain;

  _AnnotationClassFixedPoint(
      this.resolver, this.generatedLibraryId, this.elementToDomain);

  /// Returns the classes that occur as return types of covered methods or in
  /// type annotations of covered variables and parameters of covered methods,
  Iterable<ClassElement> successors(ClassElement classElement) sync* {
    bool isAppropriate(Element element) {
      return element is ClassElement &&
          _isImportable(classElement, generatedLibraryId, resolver);
    }

    _ClassDomain classDomain = elementToDomain(classElement);

    // Mixin-applications do not add further methods and fields.
    if (classDomain._classElement is MixinApplication) return;

    // Traverse type annotations to find successors. Note that we cannot
    // abstract the many redundant elements below, because `yield` cannot
    // occur in a local function.
    for (FieldElement fieldElement in classDomain._declaredFields) {
      Element fieldType = fieldElement.type.element;
      if (isAppropriate(fieldType)) yield fieldType;
    }
    for (ParameterElement parameterElement in classDomain._declaredParameters) {
      Element parameterType = parameterElement.type.element;
      if (isAppropriate(parameterType)) yield parameterType;
    }
    for (ParameterElement parameterElement in classDomain._instanceParameters) {
      Element parameterType = parameterElement.type.element;
      if (isAppropriate(parameterType)) yield parameterType;
    }
    for (ExecutableElement executableElement in classDomain._declaredMethods) {
      Element returnType = executableElement.returnType.element;
      if (isAppropriate(returnType)) yield returnType;
    }
    for (ExecutableElement executableElement in classDomain._instanceMembers) {
      Element returnType = executableElement.returnType.element;
      if (isAppropriate(returnType)) yield returnType;
    }
  }
}

// Auxiliary function used by `_generateCode`.
String _gettingClosure(String getterName) {
  String closure;
  if (new RegExp(r"^[A-Za-z$_][A-Za-z$_0-9]*$").hasMatch(getterName)) {
    // Starts with letter, not an operator.
    closure = "(dynamic instance) => instance.${getterName}";
  } else if (getterName == "[]=") {
    closure = "(dynamic instance) => (x, v) => instance[x] = v";
  } else if (getterName == "[]") {
    closure = "(dynamic instance) => (x) => instance[x]";
  } else if (getterName == "unary-") {
    closure = "(dynamic instance) => () => -instance";
  } else if (getterName == "~") {
    closure = "(dynamic instance) => () => ~instance";
  } else {
    closure = "(dynamic instance) => (x) => instance ${getterName} x";
  }
  return 'r"${getterName}": $closure';
}

// Auxiliary function used by `_generateCode`.
String _settingClosure(String setterName) {
  assert(setterName.substring(setterName.length - 1) == "=");
  // The [setterName] includes the "=", remove it.
  String name = setterName.substring(0, setterName.length - 1);

  return 'r"$setterName": (dynamic instance, value) => '
      'instance.$name = value';
}

// Auxiliary function used by `_generateCode`.
String _staticGettingClosure(_ImportCollector importCollector,
    ClassElement classElement, String getterName) {
  String className = classElement.name;
  String prefix = importCollector._getPrefix(classElement.library);
  // Operators cannot be static.
  return 'r"${getterName}": () => $prefix.$className.$getterName';
}

// Auxiliary function used by `_generateCode`.
String _staticSettingClosure(_ImportCollector importCollector,
    ClassElement classElement, String setterName) {
  assert(setterName.substring(setterName.length - 1) == "=");
  // The [setterName] includes the "=", remove it.
  String name = setterName.substring(0, setterName.length - 1);
  String className = classElement.name;
  String prefix = importCollector._getPrefix(classElement.library);
  return 'r"$setterName": (value) => $prefix.$className.$name = value';
}

// Auxiliary function used by `_generateCode`.
String _topLevelGettingClosure(_ImportCollector importCollector,
    LibraryElement library, String getterName) {
  String prefix = importCollector._getPrefix(library);
  // Operators cannot be top-level.
  return 'r"${getterName}": () => $prefix.$getterName';
}

// Auxiliary function used by `_generateCode`.
String topLevelSettingClosure(_ImportCollector importCollector,
    LibraryElement library, String setterName) {
  assert(setterName.substring(setterName.length - 1) == "=");
  // The [setterName] includes the "=", remove it.
  String name = setterName.substring(0, setterName.length - 1);
  String prefix = importCollector._getPrefix(library);
  return 'r"$setterName": (value) => $prefix.$name = value';
}

/// Information about reflectability for a given class.
class _ClassDomain {
  /// Element describing the target class.
  final ClassElement _classElement;

  /// Fields declared by [classElement] and included for reflection support,
  /// according to the reflector described by the [reflectorDomain];
  /// obtained by filtering `classElement.fields`.
  final Iterable<FieldElement> _declaredFields;

  /// Methods which are declared by [classElement] and included for
  /// reflection support, according to the reflector described by
  /// [reflectorDomain]; obtained by filtering `classElement.methods`.
  final Iterable<MethodElement> _declaredMethods;

  /// Formal parameters declared by one of the [_declaredMethods].
  final Iterable<ParameterElement> _declaredParameters;

  /// Getters and setters possessed by [classElement] and included for
  /// reflection support, according to the reflector described by
  /// [reflectorDomain]; obtained by filtering `classElement.accessors`.
  /// Note that it includes declared as well as synthetic accessors,
  /// implicitly created as getters/setters for fields.
  final Iterable<PropertyAccessorElement> _declaredAndImplicitAccessors;

  /// Constructors declared by [classElement] and included for reflection
  /// support, according to the reflector described by [reflectorDomain];
  /// obtained by filtering `classElement.constructors`.
  final Iterable<ConstructorElement> _constructors;

  /// The reflector domain that holds [this] object as one of its
  /// class domains.
  final _ReflectorDomain _reflectorDomain;

  _ClassDomain(
      this._classElement,
      this._declaredFields,
      this._declaredMethods,
      this._declaredParameters,
      this._declaredAndImplicitAccessors,
      this._constructors,
      this._reflectorDomain);

  String get _simpleName {
    if (_classElement.isMixinApplication) {
      // This is the case `class B = A with M;`.
      return _classElement.name;
    } else if (_classElement is MixinApplication) {
      // This is the case `class B extends A with M1, .. Mk {..}`
      // where `_classElement` denotes one of the mixin applications
      // that constitute the superclass chain between `B` and `A`, both
      // excluded.
      List<InterfaceType> mixins = _classElement.mixins;
      ClassElement superclass = _classElement.supertype?.element;
      String superclassName =
          superclass == null ? "null" : _qualifiedName(superclass);
      StringBuffer name = new StringBuffer(superclassName);
      bool firstSeparator = true;
      for (InterfaceType mixin in mixins) {
        name.write(firstSeparator ? " with " : ", ");
        name.write(_qualifiedName(mixin.element));
        firstSeparator = false;
      }
      return name.toString();
    } else {
      // This is a regular class, i.e., we can use its declared name.
      return _classElement.name;
    }
  }

  /// Returns the declared methods, accessors and constructors in
  /// [_classElement]. Note that this includes synthetic getters and
  /// setters, and omits fields; in other words, it provides the
  /// behavioral point of view on the class. Also note that this is not
  /// the same semantics as that of `declarations` in [ClassMirror].
  Iterable<ExecutableElement> get _declarations {
    // TODO(sigurdm) feature: Include type variables (if we keep them).
    return [_declaredMethods, _declaredAndImplicitAccessors, _constructors]
        .expand((x) => x);
  }

  /// Finds all instance members by going through the class hierarchy.
  Iterable<ExecutableElement> get _instanceMembers {
    Map<String, ExecutableElement> helper(ClassElement classElement) {
      if (_reflectorDomain._instanceMemberCache[classElement] != null) {
        return _reflectorDomain._instanceMemberCache[classElement];
      }
      Map<String, ExecutableElement> result =
          new Map<String, ExecutableElement>();

      void addIfCapable(String name, ExecutableElement member) {
        if (member.isPrivate) return;
        // If [member] is a synthetic accessor created from a field, search for
        // the metadata on the original field.
        List<ElementAnnotation> metadata = (member is PropertyAccessorElement &&
            member.isSynthetic) ? member.variable.metadata : member.metadata;
        if (_reflectorDomain._capabilities
            .supportsInstanceInvoke(member.name, metadata)) {
          result[name] = member;
        }
      }

      void addTypeIfCapable(InterfaceType type) {
        helper(type.element).forEach(addIfCapable);
      }

      void addIfCapableConcreteInstance(ExecutableElement member) {
        if (!member.isAbstract && !member.isStatic) {
          addIfCapable(member.name, member);
        }
      }

      if (classElement is MixinApplication) {
        helper(classElement.superclass).forEach(addIfCapable);
        helper(classElement.mixin).forEach(addIfCapable);
        return result;
      }
      ClassElement superclass = classElement.supertype?.element;
      if (superclass != null) helper(superclass).forEach(addIfCapable);
      classElement.mixins.forEach(addTypeIfCapable);
      classElement.methods.forEach(addIfCapableConcreteInstance);
      classElement.accessors.forEach(addIfCapableConcreteInstance);
      _reflectorDomain._instanceMemberCache[classElement] =
          new Map.unmodifiable(result);
      return result;
    }

    return helper(_classElement).values;
  }

  /// Finds all parameters of instance members.
  Iterable<ParameterElement> get _instanceParameters {
    List<ParameterElement> result = <ParameterElement>[];
    if (_reflectorDomain._capabilities._impliesDeclarations) {
      for (ExecutableElement executableElement in _instanceMembers) {
        result.addAll(executableElement.parameters);
      }
    }
    return result;
  }

  /// Finds all static members.
  Iterable<ExecutableElement> get _staticMembers {
    List<ExecutableElement> result = <ExecutableElement>[];
    if (_classElement is MixinApplication) return result;

    void possiblyAddMethod(MethodElement method) {
      if (method.isStatic &&
          !method.isPrivate &&
          _reflectorDomain._capabilities
              .supportsStaticInvoke(method.name, method.metadata)) {
        result.add(method);
      }
    }

    void possiblyAddAccessor(PropertyAccessorElement accessor) {
      if (!accessor.isStatic || accessor.isPrivate) return;
      // If [member] is a synthetic accessor created from a field, search for
      // the metadata on the original field.
      List<ElementAnnotation> metadata =
          accessor.isSynthetic ? accessor.variable.metadata : accessor.metadata;
      if (_reflectorDomain._capabilities
          .supportsStaticInvoke(accessor.name, metadata)) {
        result.add(accessor);
      }
    }

    _classElement.methods.forEach(possiblyAddMethod);
    _classElement.accessors.forEach(possiblyAddAccessor);
    return result;
  }

  String toString() {
    return "ClassDomain($_classElement)";
  }

  bool operator ==(Object other) {
    if (other is _ClassDomain) {
      return _classElement == other._classElement &&
          _reflectorDomain == other._reflectorDomain;
    } else {
      return false;
    }
  }

  int get hashCode => _classElement.hashCode ^ _reflectorDomain.hashCode;
}

/// A wrapper around a list of Capabilities.
/// Supports queries about the methods supported by the set of capabilities.
class _Capabilities {
  List<ec.ReflectCapability> _capabilities;
  _Capabilities(this._capabilities);

  bool _supportsName(ec.NamePatternCapability capability, String methodName) {
    RegExp regexp = new RegExp(capability.namePattern);
    return regexp.hasMatch(methodName);
  }

  bool _supportsMeta(ec.MetadataQuantifiedCapability capability,
      Iterable<DartObject> metadata) {
    if (metadata == null) return false;
    return metadata.map((DartObject o) => o.type).any(
        (InterfaceType interfaceType) =>
            interfaceType.isSubtypeOf(capability.metadataType.type));
  }

  bool _supportsInstanceInvoke(List<ec.ReflectCapability> capabilities,
      String methodName, Iterable<DartObjectImpl> metadata) {
    for (ec.ReflectCapability capability in capabilities) {
      // Handle API based capabilities.
      if (capability is ec.InstanceInvokeCapability &&
          _supportsName(capability, methodName)) {
        return true;
      }
      if (capability is ec.InstanceInvokeMetaCapability &&
          _supportsMeta(capability, metadata)) {
        return true;
      }
      // Quantifying capabilities have no effect on the availability of
      // specific mirror features, their semantics has already been unfolded
      // fully when the set of supported classes was computed.
    }

    // All options exhausted, give up.
    return false;
  }

  bool _supportsNewInstance(Iterable<ec.ReflectCapability> capabilities,
      String constructorName, Iterable<DartObjectImpl> metadata) {
    for (ec.ReflectCapability capability in capabilities) {
      // Handle API based capabilities.
      if ((capability is ec.InvokingCapability ||
              capability is ec.NewInstanceCapability) &&
          _supportsName(capability, constructorName)) {
        return true;
      }
      if ((capability is ec.InvokingMetaCapability ||
              capability is ec.NewInstanceMetaCapability) &&
          _supportsMeta(capability, metadata)) {
        return true;
      }
      // Quantifying capabilities have no effect on the availability of
      // specific mirror features, their semantics has already been unfolded
      // fully when the set of supported classes was computed.
    }

    // All options exhausted, give up.
    return false;
  }

  Iterable<DartObjectImpl> _getEvaluatedMetadata(
      List<ElementAnnotation> metadata) {
    return metadata.map((ElementAnnotationImpl elementAnnotation) {
      EvaluationResultImpl evaluation = elementAnnotation.evaluationResult;
      assert(evaluation != null);
      return evaluation.value;
    });
  }

  // TODO(sigurdm) future: Find a way to cache these. Perhaps take an
  // element instead of name+metadata.
  bool supportsInstanceInvoke(
      String methodName, List<ElementAnnotation> metadata) {
    var v = _supportsInstanceInvoke(
        _capabilities, methodName, _getEvaluatedMetadata(metadata));
    return v;
  }

  bool supportsNewInstance(
      String constructorName, List<ElementAnnotation> metadata) {
    var result = _supportsNewInstance(
        _capabilities, constructorName, _getEvaluatedMetadata(metadata));
    return result;
  }

  bool _supportsTopLevelInvoke(List<ec.ReflectCapability> capabilities,
      String methodName, Iterable<DartObject> metadata) {
    for (ec.ReflectCapability capability in capabilities) {
      // Handle API based capabilities.
      if ((capability is ec.TopLevelInvokeCapability) &&
          _supportsName(capability, methodName)) {
        return true;
      }
      if ((capability is ec.TopLevelInvokeMetaCapability) &&
          _supportsMeta(capability, metadata)) {
        return true;
      }
      // Quantifying capabilities do not influence the availability
      // of reflection support for top level invocation.
    }

    // All options exhausted, give up.
    return false;
  }

  bool _supportsStaticInvoke(List<ec.ReflectCapability> capabilities,
      String methodName, Iterable<DartObject> metadata) {
    for (ec.ReflectCapability capability in capabilities) {
      // Handle API based capabilities.
      if (capability is ec.StaticInvokeCapability &&
          _supportsName(capability, methodName)) {
        return true;
      }
      if (capability is ec.StaticInvokeMetaCapability &&
          _supportsMeta(capability, metadata)) {
        return true;
      }
      // Quantifying capabilities have no effect on the availability of
      // specific mirror features, their semantics has already been unfolded
      // fully when the set of supported classes was computed.
    }

    // All options exhausted, give up.
    return false;
  }

  bool supportsTopLevelInvoke(
      String methodName, List<ElementAnnotation> metadata) {
    return _supportsTopLevelInvoke(
        _capabilities, methodName, _getEvaluatedMetadata(metadata));
  }

  bool supportsStaticInvoke(
      String methodName, List<ElementAnnotation> metadata) {
    return _supportsStaticInvoke(
        _capabilities, methodName, _getEvaluatedMetadata(metadata));
  }

  bool get _supportsMetadata {
    return _capabilities.any((ec.ReflectCapability capability) =>
        capability == ec.metadataCapability);
  }

  /// Returns [true] iff these [Capabilities] specify reflection support
  /// where the set of classes must be downwards closed, i.e., extra classes
  /// must be added beyond the ones that are directly covered by the given
  /// metadata and global quantifiers, such that coverage on a class `C`
  /// implies coverage of every class `D` such that `D` is a subtype of `C`.
  bool get _impliesDownwardsClosure {
    return _capabilities.any((ec.ReflectCapability capability) =>
        capability == ec.subtypeQuantifyCapability);
  }

  /// Returns [true] iff these [Capabilities] specify reflection support where
  /// the set of included classes must be upwards closed, i.e., extra classes
  /// must be added beyond the ones that are directly included as reflectable
  /// because we must support operations like `superclass`.
  bool get _impliesUpwardsClosure {
    return _capabilities.any((ec.ReflectCapability capability) =>
        capability is ec.SuperclassQuantifyCapability);
  }

  /// Returns [true] iff these [Capabilities] specify that classes which have
  /// been used for mixin application for an included class must themselves
  /// be included (if you have `class B extends A with M ..` then the class `M`
  /// will be included if `_impliesMixins`).
  bool get _impliesMixins {
    return _capabilities.any((ec.ReflectCapability capability) =>
        capability == ec.typeRelationsCapability);
  }

  /// Maps each upper bound specified for the upwards closure to whether the
  /// bound itself is excluded, as indicated by `excludeUpperBound` in the
  /// corresponding capability. Intended usage: the `keys` of this map
  /// provides a listing of the upper bounds, and the map itself may then
  /// be consulted for each key (`if (myClosureBounds[key]) ..`) in order to
  /// take `excludeUpperBound` into account.
  Map<ClassElement, bool> get _upwardsClosureBounds {
    Map<ClassElement, bool> result = <ClassElement, bool>{};
    _capabilities.forEach((ec.ReflectCapability capability) {
      if (capability is ec.SuperclassQuantifyCapability) {
        Element element = capability.upperBound;
        if (element == null) return; // Means [Object], trivially satisfied.
        if (element is ClassElement) {
          result[element] = capability.excludeUpperBound;
        } else {
          throw new ArgumentError("Unexpected kind of upper bound specified "
              "for a `SuperclassQuantifyCapability`: $element.");
        }
      }
    });
    return result;
  }

  bool get _impliesDeclarations {
    return _capabilities.any((ec.ReflectCapability capability) {
      return capability == ec.declarationsCapability;
    });
  }

  bool get _impliesTypes {
    return _capabilities.any((ec.ReflectCapability capability) {
      return capability is ec.TypeCapability;
    });
  }

  bool get _impliesTypeAnnotations {
    return _capabilities.any((ec.ReflectCapability capability) =>
        capability is ec.TypeAnnotationQuantifyCapability);
  }

  bool get _impliesTypeAnnotationClosure {
    return _capabilities.any((ec.ReflectCapability capability) =>
        capability is ec.TypeAnnotationQuantifyCapability &&
            capability.transitive == true);
  }

  bool get supportsLibraries {
    return _capabilities.any((ec.ReflectCapability capability) =>
        capability == ec.libraryCapability);
  }
}

/// Collects the libraries that needs to be imported, and gives each library
/// a unique prefix.
class _ImportCollector {
  Map<LibraryElement, String> _mapping = new Map<LibraryElement, String>();
  int _count = 0;

  /// Returns the prefix associated with [library].
  String _getPrefix(LibraryElement library) {
    String prefix = _mapping[library];
    if (prefix != null) return prefix;
    prefix = "prefix$_count";
    _count++;
    _mapping[library] = prefix;
    return prefix;
  }

  /// Adds [library] to the collected libraries and generate a prefix for it if
  /// it has not been encountered before.
  void _addLibrary(LibraryElement library) {
    String prefix = _mapping[library];
    if (prefix != null) return;
    prefix = "prefix$_count";
    _count++;
    _mapping[library] = prefix;
  }

  Iterable<LibraryElement> get _libraries => _mapping.keys;
}

// TODO(eernst) future: Keep in mind, with reference to
// http://dartbug.com/21654 comment #5, that it would be very valuable
// if this transformation can interact smoothly with incremental
// compilation.  By nature, that is hard to achieve for a
// source-to-source translation scheme, but a long source-to-source
// translation step which is invoked frequently will certainly destroy
// the immediate feedback otherwise offered by incremental compilation.
// WORKAROUND: A work-around for this issue which is worth considering
// is to drop the translation entirely during most of development,
// because we will then simply work on a normal Dart program that uses
// dart:mirrors, which should have the same behavior as the translated
// program, and this could work quite well in practice, except for
// debugging which is concerned with the generated code (but that would
// ideally be an infrequent occurrence).

class TransformerImplementation {
  TransformLogger _logger;
  Resolver _resolver;

  /// Checks whether the given [type] from the target program is "our"
  /// class [Reflectable] by looking up the static field
  /// [Reflectable.thisClassId] and checking its value (which is a 40
  /// character string computed by sha1sum on an old version of
  /// reflectable.dart).
  ///
  /// Discussion of approach: Checking that we have found the correct
  /// [Reflectable] class is crucial for correctness, and the "obvious"
  /// approach of just looking up the library and then the class with the
  /// right names using [resolver] is unsafe.  The problems are as
  /// follows: (1) Library names are not guaranteed to be unique in a
  /// given program, so we might look up a different library named
  /// reflectable.reflectable, and a class named Reflectable in there.  (2)
  /// Library URIs (which must be unique in a given program) are not known
  /// across all usage locations for reflectable.dart, so we cannot easily
  /// predict all the possible URIs that could be used to import
  /// reflectable.dart; and it would be awkward to require that all user
  /// programs must use exactly one specific URI to import
  /// reflectable.dart.  So we use [Reflectable.thisClassId] which is very
  /// unlikely to occur with the same value elsewhere by accident.
  bool _equalsClassReflectable(ClassElement type) {
    FieldElement idField = type.getField("thisClassId");
    if (idField == null || !idField.isStatic) return false;
    if (idField is ConstFieldElementImpl) {
      EvaluationResultImpl idResult = idField.evaluationResult;
      if (idResult != null) {
        return idResult.value.stringValue == reflectable_class_constants.id;
      }
      // idResult == null: analyzer/.../element.dart does not specify
      // whether this could happen, but it is surely not the right
      // class, so we fall through.
    }
    // Not a const field, cannot be the right class.
    return false;
  }

  /// Returns the ClassElement in the target program which corresponds to class
  /// [Reflectable].
  ClassElement _findReflectableClassElement(LibraryElement reflectableLibrary) {
    for (CompilationUnitElement unit in reflectableLibrary.units) {
      for (ClassElement type in unit.types) {
        if (type.name == reflectable_class_constants.name &&
            _equalsClassReflectable(type)) {
          return type;
        }
      }
    }
    // Class [Reflectable] was not found in the target program.
    return null;
  }

  /// Returns true iff [possibleSubtype] is a direct subclass of [type].
  bool _isDirectSubclassOf(InterfaceType possibleSubtype, InterfaceType type) {
    InterfaceType superclass = possibleSubtype.superclass;
    // Even if `superclass == null` (superclass of Object), the equality
    // test will produce the correct result.
    return type == superclass;
  }

  /// Returns true iff [possibleSubtype] is a subclass of [type], including the
  /// reflexive and transitive cases.
  bool _isSubclassOf(InterfaceType possibleSubtype, InterfaceType type) {
    if (possibleSubtype == type) return true;
    InterfaceType superclass = possibleSubtype.superclass;
    if (superclass == null) return false;
    return _isSubclassOf(superclass, type);
  }

  /// Returns the metadata class in [elementAnnotation] if it is an
  /// instance of a direct subclass of [focusClass], otherwise returns
  /// `null`.  Uses [errorReporter] to report an error if it is a subclass
  /// of [focusClass] which is not a direct subclass of [focusClass],
  /// because such a class is not supported as a Reflector.
  ClassElement _getReflectableAnnotation(
      ElementAnnotation elementAnnotation, ClassElement focusClass) {
    if (elementAnnotation.element == null) {
      // This behavior is based on the assumption that a `null` element means
      // "there is no annotation here".
      return null;
    }

    /// Checks that the inheritance hierarchy placement of [type]
    /// conforms to the constraints relative to [classReflectable],
    /// which is intended to refer to the class Reflectable defined
    /// in package:reflectable/reflectable.dart. In case of violations,
    /// reports an error on [logger].
    bool checkInheritance(InterfaceType type, InterfaceType classReflectable) {
      if (!_isSubclassOf(type, classReflectable)) {
        // Not a subclass of [classReflectable] at all.
        return false;
      }
      if (!_isDirectSubclassOf(type, classReflectable)) {
        // Instance of [classReflectable], or of indirect subclass
        // of [classReflectable]: Not supported, report an error.
        _logger.error(errors.METADATA_NOT_DIRECT_SUBCLASS,
            span: _resolver.getSourceSpan(elementAnnotation.element));
        return false;
      }
      // A direct subclass of [classReflectable], all OK.
      return true;
    }

    Element element = elementAnnotation.element;
    // TODO(eernst) future: Currently we only handle constructor expressions
    // and simple identifiers.  May be generalized later.
    if (element is ConstructorElement) {
      bool isOk =
          checkInheritance(element.enclosingElement.type, focusClass.type);
      return isOk ? element.enclosingElement.type.element : null;
    } else if (element is PropertyAccessorElement) {
      PropertyInducingElement variable = element.variable;
      // Surprisingly, we have to use [ConstTopLevelVariableElementImpl]
      // here (or a similar type).  This is because none of the "public name"
      // types (types whose name does not end in `..Impl`) declare the getter
      // `evaluationResult`.  Another possible choice of type would be
      // [VariableElementImpl], but with that one we would have to test
      // `isConst` as well.
      if (variable is ConstTopLevelVariableElementImpl) {
        EvaluationResultImpl result = variable.evaluationResult;
        if (result.value == null) return null; // Errors during evaluation.
        bool isOk = checkInheritance(result.value.type, focusClass.type);
        return isOk ? result.value.type.element : null;
      } else {
        // Not a const top level variable, not relevant.
        return null;
      }
    }
    // Otherwise [element] is some other construct which is not supported.
    //
    // TODO(eernst) clarify: We need to consider whether there could be some
    // other syntactic constructs that are incorrectly assumed by programmers
    // to be usable with Reflectable.  Currently, such constructs will silently
    // have no effect; it might be better to emit a diagnostic message (a
    // hint?) in order to notify the programmer that "it does not work".
    // The trade-off is that such constructs may have been written by
    // programmers who are doing something else, intentionally.  To emit a
    // diagnostic message, we must check whether there is a Reflectable
    // somewhere inside this syntactic construct, and then emit the message
    // in cases that we "consider likely to be misunderstood".
    return null;
  }

  _warn(String message, Element element) {
    _logger.warning(message,
        asset: _resolver.getSourceAssetId(element),
        span: _resolver.getSourceSpan(element));
  }

  /// Finds all GlobalQuantifyCapability and GlobalQuantifyMetaCapability
  /// annotations on imports of [reflectableLibrary], and record the arguments
  /// of these annotations by modifying [globalPatterns] and [globalMetadata].
  void _findGlobalQuantifyAnnotations(
      Map<RegExp, List<ClassElement>> globalPatterns,
      Map<ClassElement, List<ClassElement>> globalMetadata) {
    LibraryElement reflectableLibrary =
        _resolver.getLibraryByName("reflectable.reflectable");
    LibraryElement capabilityLibrary =
        _resolver.getLibraryByName("reflectable.capability");
    ClassElement reflectableClass = reflectableLibrary.getType("Reflectable");
    ClassElement typeClass =
        _resolver.getLibraryByUri(Uri.parse("dart:core")).getType("Type");

    ConstructorElement globalQuantifyCapabilityConstructor = capabilityLibrary
        .getType("GlobalQuantifyCapability")
        .getNamedConstructor("");
    ConstructorElement globalQuantifyMetaCapabilityConstructor =
        capabilityLibrary
            .getType("GlobalQuantifyMetaCapability")
            .getNamedConstructor("");

    for (LibraryElement library in _resolver.libraries) {
      for (ImportElement import in library.imports) {
        for (ElementAnnotationImpl metadatum in import.metadata) {
          if (metadatum.element == globalQuantifyCapabilityConstructor) {
            EvaluationResultImpl evaluation = metadatum.evaluationResult;
            if (evaluation != null && evaluation.value != null) {
              DartObjectImpl value = evaluation.value;
              String pattern = value.fields["classNamePattern"].stringValue;
              if (pattern == null) {
                // TODO(sigurdm) implement: Create a span for the annotation
                // rather than the import.
                _warn("The classNamePattern must be a string", import);
                continue;
              }
              ClassElement reflector =
                  value.fields["(super)"].fields["reflector"].type.element;
              if (reflector == null ||
                  reflector.type.element.supertype.element !=
                      reflectableClass) {
                String found =
                    reflector == null ? "" : " Found ${reflector.name}";
                _warn(
                    "The reflector must be a direct subclass of Reflectable." +
                        found,
                    import);
                continue;
              }
              globalPatterns
                  .putIfAbsent(
                      new RegExp(pattern), () => new List<ClassElement>())
                  .add(reflector);
            }
          } else if (metadatum.element ==
              globalQuantifyMetaCapabilityConstructor) {
            EvaluationResultImpl evaluation = metadatum.evaluationResult;
            if (evaluation != null && evaluation.value != null) {
              DartObjectImpl value = evaluation.value;
              Object metadataFieldValue = value.fields["metadataType"].value;
              if (metadataFieldValue == null ||
                  value.fields["metadataType"].type.element != typeClass) {
                // TODO(sigurdm) implement: Create a span for the annotation.
                _warn(
                    "The metadata must be a Type. "
                    "Found ${value.fields["metadataType"].type.element.name}",
                    import);
                continue;
              }
              ClassElement reflector =
                  value.fields["(super)"].fields["reflector"].type.element;
              if (reflector == null ||
                  reflector.type.element.supertype.element !=
                      reflectableClass) {
                String found =
                    reflector == null ? "" : " Found ${reflector.name}";
                _warn(
                    "The reflector must be a direct subclass of Reflectable." +
                        found,
                    import);
                continue;
              }
              globalMetadata
                  .putIfAbsent(
                      metadataFieldValue, () => new List<ClassElement>())
                  .add(reflector);
            }
          }
        }
      }
    }
  }

  /// Returns a [ReflectionWorld] instantiated with all the reflectors seen by
  /// [_resolver] and all classes annotated by them. The [reflectableLibrary]
  /// must be the element representing 'package:reflectable/reflectable.dart',
  /// the [entryPoint] must be the element representing the entry point under
  /// transformation, and [dataId] must represent the entry point as well,
  /// and it is used to decide whether it is possible to import other libraries
  /// from the entry point. If the transformation is guaranteed to have no
  /// effect the return value is [null].
  ReflectionWorld _computeWorld(LibraryElement reflectableLibrary,
      LibraryElement entryPoint, AssetId dataId) {
    final ClassElement classReflectable =
        _findReflectableClassElement(reflectableLibrary);
    // If class `Reflectable` is absent the transformation must be a no-op.
    if (classReflectable == null) return null;

    // The world will be built from the library arguments plus these two.
    final Map<ClassElement, _ReflectorDomain> domains =
        new Map<ClassElement, _ReflectorDomain>();
    final _ImportCollector importCollector = new _ImportCollector();

    // Maps each pattern to the list of reflectors associated with it via
    // a [GlobalQuantifyCapability].
    Map<RegExp, List<ClassElement>> globalPatterns =
        new Map<RegExp, List<ClassElement>>();

    // Maps each [Type] to the list of reflectors associated with it via
    // a [GlobalQuantifyMetaCapability].
    Map<ClassElement, List<ClassElement>> globalMetadata =
        new Map<ClassElement, List<ClassElement>>();

    final LibraryElement capabilityLibrary =
        _resolver.getLibraryByName("reflectable.capability");

    /// Gets the [ReflectorDomain] associated with [reflector], or creates
    /// it if none exists.
    _ReflectorDomain getReflectorDomain(ClassElement reflector) {
      return domains.putIfAbsent(reflector, () {
        _Capabilities capabilities =
            _capabilitiesOf(capabilityLibrary, reflector);
        assert(_isImportableLibrary(reflector.library, dataId, _resolver));
        importCollector._addLibrary(reflector.library);
        return new _ReflectorDomain(_resolver, dataId, reflector, capabilities);
      });
    }

    /// Adds [library] to the supported libraries of [reflector].
    void addLibrary(LibraryElement library, ClassElement reflector) {
      _ReflectorDomain domain = getReflectorDomain(reflector);
      if (domain._capabilities.supportsLibraries) {
        assert(_isImportableLibrary(reflector.library, dataId, _resolver));
        importCollector._addLibrary(library);
        domain._libraries.add(library);
      }
    }

    /// Adds a [_ClassDomain] representing [type] to the supported classes of
    /// [reflector]; also adds the enclosing library of [type] to the
    /// supported libraries.
    void addClassDomain(ClassElement type, ClassElement reflector) {
      if (!_isImportable(type, dataId, _resolver)) {
        _logger.fine("Ignoring unrepresentable class ${type.name}",
            asset: _resolver.getSourceAssetId(type),
            span: _resolver.getSourceSpan(type));
      } else {
        _ReflectorDomain domain = getReflectorDomain(reflector);
        if (!domain._classes.contains(type)) {
          if (type.isMixinApplication) {
            // Iterate over all mixins in most-general-first order (so with
            // `class C extends B with M1, M2..` we visit `M1` then `M2`.
            ClassElement superclass = type.supertype.element;
            for (InterfaceType mixin in type.mixins) {
              ClassElement mixinElement = mixin.element;
              ClassElement subClass = mixin == type.mixins.last ? type : null;
              String name = subClass == null ? null : type.name;
              MixinApplication mixinApplication = new MixinApplication(
                  name, superclass, mixinElement, type.library, subClass);
              domain._classes.add(mixinApplication);
              superclass = mixinApplication;
            }
          } else {
            domain._classes.add(type);
          }
          addLibrary(type.library, reflector);
          // We need to ensure that the [importCollector] has indeed added
          // `type.library` (if we have no library capability `addLibrary` will
          // not do that), because it may be needed in import directives in the
          // generated library, even in cases where the transformed program
          // will not get library support.
          // TODO(eernst) clarify: Maybe the following statement could be moved
          // out of the `if` in `addLibrary` such that we don't have to have
          // an extra copy of it here.
          importCollector._addLibrary(type.library);
        }
      }
    }

    /// Runs through a list of metadata, and finds any Reflectors, and
    /// objects that are associated with reflectors via
    /// GlobalQuantifyMetaCapability and GlobalQuantifyCapability.
    /// [qualifiedName] is the name of the library or class annotated by
    /// metadata.
    Iterable<ClassElement> getReflectors(
        String qualifiedName, List<ElementAnnotation> metadata) {
      List<ClassElement> result = new List<ClassElement>();

      for (ElementAnnotationImpl metadatum in metadata) {
        EvaluationResultImpl evaluation = metadatum.evaluationResult;
        DartObject value = evaluation.value;

        // Test if the type of this metadata is associated with any reflectors
        // via GlobalQuantifyMetaCapability.
        if (value != null) {
          List<ClassElement> reflectors = globalMetadata[value.type.element];
          if (reflectors != null) {
            for (ClassElement reflector in reflectors) {
              result.add(reflector);
            }
          }
        }

        // Test if the annotation is a reflector.
        ClassElement reflector =
            _getReflectableAnnotation(metadatum, classReflectable);
        if (reflector != null) {
          result.add(reflector);
        }
      }

      // Add All reflectors associated with a
      // pattern, via GlobalQuantifyCapability, that matches the qualified
      // name of the class or library.
      globalPatterns.forEach((RegExp pattern, List<ClassElement> reflectors) {
        if (pattern.hasMatch(qualifiedName)) {
          for (ClassElement reflector in reflectors) {
            result.add(reflector);
          }
        }
      });
      return result;
    }

    // Populate [globalPatterns] and [globalMetadata].
    _findGlobalQuantifyAnnotations(globalPatterns, globalMetadata);

    // Visits all libraries and all classes in the given entry point,
    // gets their reflectors, and adds them to the domain of that
    // reflector.
    for (LibraryElement library in _resolver.libraries) {
      for (ClassElement reflector
          in getReflectors(library.name, library.metadata)) {
        assert(_isImportableLibrary(reflector.library, dataId, _resolver));
        addLibrary(library, reflector);
      }

      for (CompilationUnitElement unit in library.units) {
        for (ClassElement type in unit.types) {
          for (ClassElement reflector
              in getReflectors(_qualifiedName(type), type.metadata)) {
            addClassDomain(type, reflector);
          }
        }
      }
    }

    return new ReflectionWorld(_resolver, dataId, domains.values.toList(),
        reflectableLibrary, entryPoint, importCollector);
  }

  /// Returns the [ReflectCapability] denoted by the given [initializer].
  ec.ReflectCapability _capabilityOfExpression(LibraryElement capabilityLibrary,
      Expression expression, LibraryElement containingLibrary) {
    EvaluationResult evaluated =
        _resolver.evaluateConstant(containingLibrary, expression);

    if (!evaluated.isValid) {
      _logger.error("Invalid constant $expression in capability-list.");
    }

    DartObjectImpl constant = evaluated.value;

    ParameterizedType dartType = constant.type;
    // We insist that the type must be a class, and we insist that it must
    // be in the given `capabilityLibrary` (because we could never know
    // how to interpret the meaning of a user-written capability class, so
    // users cannot write their own capability classes).
    if (dartType.element is! ClassElement) {
      if (dartType.element.source != null) {
        _logger.error(
            errors.applyTemplate(errors.SUPER_ARGUMENT_NON_CLASS,
                {"type": dartType.displayName}),
            span: _resolver.getSourceSpan(dartType.element));
      } else {
        _logger.error(errors.applyTemplate(
            errors.SUPER_ARGUMENT_NON_CLASS, {"type": dartType.displayName}));
      }
    }
    ClassElement classElement = dartType.element;
    if (classElement.library != capabilityLibrary) {
      _logger.error(
          errors.applyTemplate(errors.SUPER_ARGUMENT_WRONG_LIBRARY,
              {"library": capabilityLibrary, "element": classElement}),
          span: _resolver.getSourceSpan(classElement));
    }

    /// Extracts the namePattern String from an instance of a subclass of
    /// NamePatternCapability.
    String extractNamePattern(DartObjectImpl constant) {
      if (constant.fields == null ||
          constant.fields["(super)"] == null ||
          constant.fields["(super)"].fields["namePattern"] == null ||
          constant.fields["(super)"].fields["namePattern"].stringValue ==
              null) {
        // TODO(sigurdm) diagnostic: Better error-message.
        _logger.warning("Could not extract namePattern.");
      }
      return constant.fields["(super)"].fields["namePattern"].stringValue;
    }

    /// Extracts the metadata property from an instance of a subclass of
    /// MetadataCapability.
    ClassElement extractMetaData(DartObjectImpl constant) {
      if (constant.fields == null ||
          constant.fields["(super)"] == null ||
          constant.fields["(super)"].fields["metadataType"] == null) {
        // TODO(sigurdm) diagnostic: Better error-message. We need a way
        // to get a source location from a constant.
        _logger.warning("Could not extract the metadata field.");
        return null;
      }
      Object metadataFieldValue =
          constant.fields["(super)"].fields["metadataType"].value;
      if (metadataFieldValue is! ClassElement) {
        _logger.warning("The metadataType field must be a Type object.");
        return null;
      }
      return constant.fields["(super)"].fields["metadataType"].value;
    }

    switch (classElement.name) {
      case "_NameCapability":
        return ec.nameCapability;
      case "_ClassifyCapability":
        return ec.classifyCapability;
      case "_MetadataCapability":
        return ec.metadataCapability;
      case "_TypeRelationsCapability":
        return ec.typeRelationsCapability;
      case "_LibraryCapability":
        return ec.libraryCapability;
      case "_DeclarationsCapability":
        return ec.declarationsCapability;
      case "_UriCapability":
        return ec.uriCapability;
      case "_LibraryDependenciesCapability":
        return ec.libraryDependenciesCapability;
      case "InstanceInvokeCapability":
        return new ec.InstanceInvokeCapability(extractNamePattern(constant));
      case "InstanceInvokeMetaCapability":
        return new ec.InstanceInvokeMetaCapability(extractMetaData(constant));
      case "StaticInvokeCapability":
        return new ec.StaticInvokeCapability(extractNamePattern(constant));
      case "StaticInvokeMetaCapability":
        return new ec.StaticInvokeMetaCapability(extractMetaData(constant));
      case "TopLevelInvokeCapability":
        return new ec.TopLevelInvokeCapability(extractNamePattern(constant));
      case "TopLevelInvokeMetaCapability":
        return new ec.TopLevelInvokeMetaCapability(extractMetaData(constant));
      case "NewInstanceCapability":
        return new ec.NewInstanceCapability(extractNamePattern(constant));
      case "NewInstanceMetaCapability":
        return new ec.NewInstanceMetaCapability(extractMetaData(constant));
      case "TypeCapability":
        return new ec.TypeCapability();
      case "InvokingCapability":
        return new ec.InvokingCapability(extractNamePattern(constant));
      case "InvokingMetaCapability":
        return new ec.NewInstanceMetaCapability(extractMetaData(constant));
      case "TypingCapability":
        return new ec.TypingCapability();
      case "_SubtypeQuantifyCapability":
        return ec.subtypeQuantifyCapability;
      case "SuperclassQuantifyCapability":
        return new ec.SuperclassQuantifyCapability(
            constant.fields["upperBound"].value,
            excludeUpperBound: constant.fields["excludeUpperBound"].value);
      case "TypeAnnotationQuantifyCapability":
        return new ec.TypeAnnotationQuantifyCapability(
            transitive: constant.fields["transitive"].value);
      case "AdmitSubtypeCapability":
        // TODO(eernst) feature:
        throw new UnimplementedError("$classElement not yet supported!");
      default:
        throw new UnimplementedError("Unexpected capability $classElement");
    }
  }

  /// Returns the list of Capabilities given given as a superinitializer by the
  /// reflector.
  _Capabilities _capabilitiesOf(
      LibraryElement capabilityLibrary, ClassElement reflector) {
    List<ConstructorElement> constructors = reflector.constructors;
    // The superinitializer must be unique, so there must be 1 constructor.
    assert(constructors.length == 1);
    ConstructorElement constructorElement = constructors[0];
    // It can only be a const constructor, because this class has been
    // used for metadata; it is a bug in the transformer if not.
    // It must also be a default constructor.
    assert(constructorElement.isConst);
    // TODO(eernst) clarify: Ensure that some other location in this
    // transformer checks that the reflector class constructor is indeed a
    // default constructor, such that this can be a mere assertion rather than
    // a user-oriented error report.
    assert(constructorElement.isDefaultConstructor);

    ConstructorDeclaration constructorDeclarationNode =
        constructorElement.computeNode();
    NodeList<ConstructorInitializer> initializers =
        constructorDeclarationNode.initializers;

    if (initializers.length == 0) {
      // Degenerate case: Without initializers, we will obtain a reflector
      // without any capabilities, which is not useful in practice. We do
      // have this degenerate case in tests "just because we can", and
      // there is no technical reason to prohibit it, so we will handle
      // it here.
      return new _Capabilities(<ec.ReflectCapability>[]);
    }
    // TODO(eernst) clarify: Ensure again that this can be a mere assertion.
    assert(initializers.length == 1);

    // Main case: the initializer is exactly one element. We must
    // handle two cases: `super(..)` and `super.fromList(<_>[..])`.
    SuperConstructorInvocation superInvocation = initializers[0];

    ec.ReflectCapability capabilityOfExpression(Expression expression) {
      return _capabilityOfExpression(
          capabilityLibrary, expression, reflector.library);
    }

    if (superInvocation.constructorName == null) {
      // Subcase: `super(..)` where 0..k arguments are accepted for some
      // k that we need not worry about here.
      NodeList<Expression> arguments = superInvocation.argumentList.arguments;
      return new _Capabilities(arguments.map(capabilityOfExpression).toList());
    }
    assert(superInvocation.constructorName == "fromList");

    // Subcase: `super.fromList(const <..>[..])`.
    NodeList<Expression> arguments = superInvocation.argumentList.arguments;
    assert(arguments.length == 1);
    ListLiteral listLiteral = arguments[0];
    NodeList<Expression> expressions = listLiteral.elements;
    return new _Capabilities(expressions.map(capabilityOfExpression).toList());
  }

  /// Generates code for a new entry-point file that will initialize the
  /// reflection data according to [world], and invoke the main of
  /// [entrypointLibrary] located at [originalEntryPointFilename]. The code is
  /// generated to be located at [generatedId].
  String _generateNewEntryPoint(ReflectionWorld world, AssetId generatedId,
      String originalEntryPointFilename) {
    // Notice it is important to generate the code before printing the
    // imports because generating the code can add further imports.
    String code = world.generateCode(_logger);

    List<String> imports = new List<String>();
    world.importCollector._libraries.forEach((LibraryElement library) {
      Uri uri = library == world.entryPointLibrary
          ? originalEntryPointFilename
          : _resolver.getImportUri(library, from: generatedId);
      String prefix = world.importCollector._getPrefix(library);
      imports.add("import '$uri' as $prefix;");
    });
    imports.sort();

    String args = (world.entryPointLibrary.entryPoint.parameters.length == 0)
        ? ""
        : "args";
    return """
// This file has been generated by the reflectable package.
// https://github.com/dart-lang/reflectable.

library reflectable_generated_main_library;

import "dart:core";
import "$originalEntryPointFilename" as original show main;
${imports.join('\n')}

import "package:reflectable/mirrors.dart" as m;
import "package:reflectable/src/reflectable_transformer_based.dart" as r;
import "package:reflectable/reflectable.dart" show isTransformed;

export "$originalEntryPointFilename" hide main;

main($args) {
  _initializeReflectable();
  return original.main($args);
}

final _data = ${code};

_initializeReflectable() {
  if (!isTransformed) {
    throw new UnsupportedError(
        "The transformed code is running with the untransformed "
        "reflectable package. Remember to set your package-root to "
        "'build/.../packages'.");
  }
  r.data = _data;
}
""";
  }

  /// Performs the transformation which eliminates all imports of
  /// `package:reflectable/reflectable.dart` and instead provides a set of
  /// statically generated mirror classes.
  Future apply(
      AggregateTransform aggregateTransform, List<String> entryPoints) async {
    _logger = aggregateTransform.logger;
    // The type argument in the return type is omitted because the
    // documentation on barback and on transformers do not specify it.

    List<Asset> assets = await aggregateTransform.primaryInputs.toList();

    if (assets.isEmpty) {
      // It is not an error to have nothing to transform.
      _logger.info("Nothing to transform");
      // Terminate with a non-failing status code to the OS.
      exit(0);
    }

    // TODO(eernst) algorithm: Build a mapping from entry points to assets by
    // iterating over `assets` and doing a binary search on a sorted
    // list of entry points: if A is the number of assets and E is the
    // number of entry points (note: E < A, and E == 1 could be quite
    // common), this would cost O(A*log(E)), whereas the current
    // approach costs O(A*E). OK, it's log(E)+epsilon, not 0 when E == 1.
    for (String entryPoint in entryPoints) {
      // Find the asset corresponding to [entryPoint]
      Asset entryPointAsset = assets.firstWhere(
          (Asset asset) => asset.id.path.endsWith(entryPoint),
          orElse: () => null);
      if (entryPointAsset == null) {
        aggregateTransform.logger.info("Missing entry point: $entryPoint");
        continue;
      }
      Transform wrappedTransform =
          new _AggregateTransformWrapper(aggregateTransform, entryPointAsset);

      _resolver = await _resolvers.get(wrappedTransform);
      LibraryElement reflectableLibrary =
          _resolver.getLibraryByName("reflectable.reflectable");
      if (reflectableLibrary == null) {
        // Stop and do not consumePrimary, i.e., let the original source
        // pass through without changes.
        continue;
      }

      LibraryElement entryPointLibrary =
          _resolver.getLibrary(entryPointAsset.id);

      ReflectionWorld world = _computeWorld(
          reflectableLibrary, entryPointLibrary, entryPointAsset.id);
      if (world == null) continue;

      String source = await entryPointAsset.readAsString();
      AssetId originalEntryPointId =
          entryPointAsset.id.changeExtension("_reflectable_original_main.dart");
      // Rename the original entry-point.
      aggregateTransform
          .addOutput(new Asset.fromString(originalEntryPointId, source));

      String originalEntryPointFilename =
          path.basename(originalEntryPointId.path);

      if (entryPointLibrary.entryPoint == null) {
        aggregateTransform.logger.info(
            "Entry point: $entryPoint has no member called `main`. Skipping.");
        continue;
      }

      // Generate a new file with the name of the entry-point, whose main
      // initializes the reflection data, and calls the main from
      // [originalEntryPointId].
      aggregateTransform.addOutput(new Asset.fromString(
          entryPointAsset.id,
          _generateNewEntryPoint(
              world, entryPointAsset.id, originalEntryPointFilename)));
      _resolver.release();
    }
  }
}

/// Wrapper of `AggregateTransform` of type `Transform`, allowing us to
/// get a `Resolver` for a given `AggregateTransform` with a given
/// selection of a primary entry point.
/// TODO(eernst) future: We will just use this temporarily; code_transformers
/// may be enhanced to support a variant of Resolvers.get that takes an
/// [AggregateTransform] and an [Asset] rather than a [Transform], in
/// which case we can drop this class and use that method.
class _AggregateTransformWrapper implements Transform {
  final AggregateTransform _aggregateTransform;
  final Asset primaryInput;
  _AggregateTransformWrapper(this._aggregateTransform, this.primaryInput);
  TransformLogger get logger => _aggregateTransform.logger;
  Future<Asset> getInput(AssetId id) => _aggregateTransform.getInput(id);
  Future<String> readInputAsString(AssetId id, {Encoding encoding}) {
    return _aggregateTransform.readInputAsString(id, encoding: encoding);
  }

  Stream<List<int>> readInput(AssetId id) => _aggregateTransform.readInput(id);
  Future<bool> hasInput(AssetId id) => _aggregateTransform.hasInput(id);
  void addOutput(Asset output) => _aggregateTransform.addOutput(output);
  void consumePrimary() => _aggregateTransform.consumePrimary(primaryInput.id);
}

bool _accessorIsntImplicitGetterOrSetter(PropertyAccessorElement accessor) {
  return !accessor.isSynthetic || (!accessor.isGetter && !accessor.isSetter);
}

bool _executableIsntImplicitGetterOrSetter(ExecutableElement executable) {
  return executable is! PropertyAccessorElement ||
      _accessorIsntImplicitGetterOrSetter(executable);
}

/// Returns an integer encoding of the kind and attributes of the given
/// field.
int _fieldDescriptor(FieldElement element) {
  int result = constants.field;
  if (element.isPrivate) result |= constants.privateAttribute;
  if (element.isSynthetic) result |= constants.syntheticAttribute;
  if (element.isConst) {
    result |= constants.constAttribute;
    // We will get `false` from `element.isFinal` in this case, but with
    // a mirror from 'dart:mirrors' it is considered to be "implicitly
    // final", so we follow that and ignore `element.isFinal`.
    result |= constants.finalAttribute;
  } else {
    if (element.isFinal) result |= constants.finalAttribute;
  }
  if (element.isStatic) result |= constants.staticAttribute;
  if (element.type.isDynamic) {
    result |= constants.dynamicAttribute;
  }
  Element elementType = element.type.element;
  if (elementType is ClassElement) {
    result |= constants.classTypeAttribute;
  }
  return result;
}

/// Returns an integer encoding of the kind and attributes of the given
/// parameter.
int _parameterDescriptor(ParameterElement element) {
  int result = constants.parameter;
  if (element.isPrivate) result |= constants.privateAttribute;
  if (element.isSynthetic) result |= constants.syntheticAttribute;
  if (element.isConst) result |= constants.constAttribute;
  if (element.isFinal) result |= constants.finalAttribute;
  if (element.defaultValueCode != null) {
    result |= constants.hasDefaultValueAttribute;
  }
  if (element.parameterKind.isOptional) {
    result |= constants.optionalAttribute;
  }
  if (element.parameterKind == ParameterKind.NAMED) {
    result |= constants.namedAttribute;
  }
  if (element.type.isDynamic) {
    result |= constants.dynamicAttribute;
  }
  Element elementType = element.type.element;
  if (elementType is ClassElement) {
    result |= constants.classTypeAttribute;
  }
  return result;
}

/// Returns an integer encoding of the kind and attributes of the given
/// method/constructor/getter/setter.
int _declarationDescriptor(ExecutableElement element) {
  int result;

  void handleReturnType(ExecutableElement element) {
    if (element.returnType.isDynamic) {
      result |= constants.dynamicReturnTypeAttribute;
    }
    if (element.returnType.isVoid) {
      result |= constants.voidReturnTypeAttribute;
    }
    Element elementReturnType = element.returnType.element;
    if (elementReturnType is ClassElement) {
      result |= constants.classReturnTypeAttribute;
    }
  }

  if (element is PropertyAccessorElement) {
    result = element.isGetter ? constants.getter : constants.setter;
    handleReturnType(element);
  } else if (element is ConstructorElement) {
    if (element.isFactory) {
      result = constants.factoryConstructor;
    } else {
      result = constants.generativeConstructor;
    }
    if (element.isConst) result |= constants.constAttribute;
    if (element.redirectedConstructor != null) {
      result |= constants.redirectingConstructorAttribute;
    }
  } else {
    assert(element is MethodElement);
    result = constants.method;
    handleReturnType(element);
  }
  if (element.isPrivate) result |= constants.privateAttribute;
  if (element.isStatic) result |= constants.staticAttribute;
  if (element.isSynthetic) result |= constants.syntheticAttribute;
  if (element.isAbstract) result |= constants.abstractAttribute;
  return result;
}

String _nameOfDeclaration(ExecutableElement element) {
  if (element is ConstructorElement) {
    return element.name == ""
        ? element.enclosingElement.name
        : "${element.enclosingElement.name}.${element.name}";
  }
  return element.name;
}

String _formatAsList(String typeName, Iterable parts) =>
    "<$typeName>[${parts.join(", ")}]";

String _formatAsDynamicList(Iterable parts) => "[${parts.join(", ")}]";

String _formatAsMap(Iterable parts) => "{${parts.join(", ")}}";

/// Returns a [String] containing code that will evaluate to the same
/// value when evaluated in the generated file as the given [expression]
/// would evaluate to in [originatingLibrary].
String _extractConstantCode(
    Expression expression,
    LibraryElement originatingLibrary,
    _ImportCollector importCollector,
    TransformLogger logger,
    AssetId generatedLibraryId,
    Resolver resolver) {
  String helper(Expression expression) {
    if (expression is ListLiteral) {
      List<String> elements =
          expression.elements.map((Expression subExpression) {
        return helper(subExpression);
      });
      // TODO(sigurdm) feature: Type arguments.
      return "const ${_formatAsDynamicList(elements)}";
    } else if (expression is MapLiteral) {
      List<String> elements = expression.entries.map((MapLiteralEntry entry) {
        String key = helper(entry.key);
        String value = helper(entry.value);
        return "$key: $value";
      });
      // TODO(sigurdm) feature: Type arguments.
      return "const ${_formatAsMap(elements)}";
    } else if (expression is InstanceCreationExpression) {
      String constructor = expression.constructorName.toSource();
      LibraryElement libraryOfConstructor = expression.staticElement.library;
      if (_isImportableLibrary(
          libraryOfConstructor, generatedLibraryId, resolver)) {
        importCollector._addLibrary(libraryOfConstructor);
        String prefix =
            importCollector._getPrefix(expression.staticElement.library);
        // TODO(sigurdm) implement: Named arguments.
        String arguments =
            expression.argumentList.arguments.map((Expression argument) {
          return helper(argument);
        }).join(", ");
        // TODO(sigurdm) feature: Type arguments.
        return "const $prefix.$constructor($arguments)";
      } else {
        logger.error("Cannot access library $libraryOfConstructor, "
            "needed for expression $expression");
        return "";
      }
    } else if (expression is Identifier) {
      if (Identifier.isPrivateName(expression.name)) {
        Element staticElement = expression.staticElement;
        if (staticElement is PropertyAccessorElement) {
          VariableElement variable = staticElement.variable;
          VariableDeclaration variableDeclaration = variable.computeNode();
          return helper(variableDeclaration.initializer);
        } else {
          logger.error("Cannot handle private identifier $expression");
          return "";
        }
      } else {
        Element element = expression.staticElement;
        if (_isImportableLibrary(
            element.library, generatedLibraryId, resolver)) {
          importCollector._addLibrary(element.library);
          String prefix = importCollector._getPrefix(element.library);
          Element enclosingElement = element.enclosingElement;
          if (enclosingElement is ClassElement) {
            prefix += ".${enclosingElement.name}";
          }
          return "$prefix.${element.name}";
        } else {
          logger.error("Cannot access library ${element.library}, "
              "needed for expression $expression");
          return "";
        }
      }
    } else if (expression is BinaryExpression) {
      String a = helper(expression.leftOperand);
      String op = expression.operator.lexeme;
      String b = helper(expression.rightOperand);
      return "$a $op $b";
    } else if (expression is ConditionalExpression) {
      String condition = helper(expression.condition);
      String a = helper(expression.thenExpression);
      String b = helper(expression.elseExpression);
      return "$condition ? $a : $b";
    } else if (expression is ParenthesizedExpression) {
      String nested = helper(expression.expression);
      return "($nested)";
    } else if (expression is PropertyAccess) {
      String target = helper(expression.target);
      String selector = expression.propertyName.token.lexeme;
      return "$target.$selector";
    } else if (expression is MethodInvocation) {
      // We only handle "identical(a, b)".
      assert(expression.target == null);
      assert(expression.methodName.token.lexeme == "identical");
      NodeList arguments = expression.argumentList.arguments;
      assert(arguments.length == 2);
      String a = helper(arguments[0]);
      String b = helper(arguments[1]);
      return "identical($a, $b)";
    } else {
      assert(expression is IntegerLiteral ||
          expression is BooleanLiteral ||
          expression is StringLiteral ||
          expression is NullLiteral ||
          expression is SymbolLiteral ||
          expression is DoubleLiteral ||
          expression is TypedLiteral);
      return expression.toSource();
    }
  }
  return helper(expression);
}

/// Returns a [String] containing code that will evaluate to the same
/// value when evaluated as an expression in the generated file as the
/// given [annotation] when attached as metadata to a declaration in
/// the given [library].
String _extractAnnotationValue(Annotation annotation, LibraryElement library,
    _ImportCollector importCollector) {
  String keywordCode = annotation.arguments != null ? "const " : "";
  Identifier name = annotation.name;
  String _nullIsEmpty(Object object) => object == null ? "" : "$object";
  if (name is SimpleIdentifier) {
    return "$keywordCode"
        "${importCollector._getPrefix(library)}.$name"
        "${_nullIsEmpty(annotation.period)}"
        "${_nullIsEmpty(annotation.constructorName)}"
        "${_nullIsEmpty(annotation.arguments)}";
  }
  throw new UnimplementedError(
      "Cannot move this annotation: $annotation, from library $library");
}

/// The names of the libraries that can be accessed with a 'dart:x' import uri.
Set<String> sdkLibraryNames = new Set.from([
  "async",
  "collection",
  "convert",
  "core",
  "developer",
  "html",
  "indexed_db",
  "io",
  "isolate",
  "js",
  "math",
  "mirrors",
  "profiler",
  "svg",
  "typed_data",
  "web_audio",
  "web_gl",
  "web_sql"
]);

/// Returns a String with the code used to build the metadata of [element].
///
/// Also adds any neccessary imports to [importCollector].
String _extractMetadataCode(Element element, Resolver resolver,
    _ImportCollector importCollector, TransformLogger logger, AssetId dataId) {
  Iterable<ElementAnnotation> elementAnnotations = element.metadata;

  if (elementAnnotations == null) return "<Object>[]";

  // Synthetic accessors do not have metadata. Only their associated fields.
  if ((element is PropertyAccessorElement ||
          element is ConstructorElement ||
          element is MixinApplication) &&
      element.isSynthetic) {
    return "<Object>[]";
  }

  List<String> metadataParts = new List<String>();

  AstNode node = element.computeNode();
  if (node == null) {
    // This can occur with members of subclasses of `Element` from 'dart:html'.
    return "<Object>[]";
  }

  // The `element.node` of a field is the [VariableDeclaration] that is nested
  // in a [VariableDeclarationList] that is nested in a [FieldDeclaration]. The
  // metadata is stored on the [FieldDeclaration].
  //
  // Similarly the `element.node` of a libraryElement is the identifier that
  // forms its name. The parent's parent is the actual Library declaration that
  // contains the metadata.
  if (element is FieldElement || element is LibraryElement) {
    node = node.parent.parent;
  }

  AnnotatedNode annotatedNode = node;
  for (Annotation annotationNode in annotatedNode.metadata) {
    // TODO(sigurdm) diagnostic: Emit a warning/error if the element is not
    // in the global public scope of the library.
    if (annotationNode.element == null) {
      // Some internal constants (mainly in dart:html) cannot be resolved by
      // the analyzer. Ignore them.
      // TODO(sigurdm) clarify: Investigate this, and see if these constants can
      // somehow be included.
      logger.fine("Ignoring unresolved metadata $annotationNode",
          asset: resolver.getSourceAssetId(element),
          span: resolver.getSourceSpan(element));
      continue;
    }

    LibraryElement library = annotationNode.element.library;
    if (!_isImportable(annotationNode.element, dataId, resolver)) {
      // Private constants, and constants made of classes in internal libraries
      // cannot be represented.
      // Skip them.
      // TODO(sigurdm) clarify: Investigate this, and see if these constants can
      // somehow be included.
      logger.fine("Ignoring unrepresentable metadata $annotationNode",
          asset: resolver.getSourceAssetId(element),
          span: resolver.getSourceSpan(element));
      continue;
    }
    importCollector._addLibrary(library);
    String prefix = importCollector._getPrefix(library);
    if (annotationNode.arguments != null) {
      // A const constructor.
      String constructor = (annotationNode.constructorName == null)
          ? annotationNode.name
          : "${annotationNode.name}.${annotationNode.constructorName}";
      String arguments =
          annotationNode.arguments.arguments.map((Expression argument) {
        return _extractConstantCode(argument, element.library, importCollector,
            logger, dataId, resolver);
      }).join(", ");
      metadataParts.add("const $prefix.$constructor($arguments)");
    } else {
      // A field reference.
      metadataParts.add("$prefix.${annotationNode.name}");
    }
  }

  return _formatAsList("Object", metadataParts);
}

Iterable<FieldElement> _extractDeclaredFields(
    ClassElement classElement, _Capabilities capabilities) {
  return classElement.fields.where((FieldElement field) {
    if (field.isPrivate) return false;
    Function capabilityChecker = field.isStatic
        ? capabilities.supportsStaticInvoke
        : capabilities.supportsInstanceInvoke;
    return !field.isSynthetic && capabilityChecker(field.name, field.metadata);
  });
}

Iterable<MethodElement> _extractDeclaredMethods(
    ClassElement classElement, _Capabilities capabilities) {
  return classElement.methods.where((MethodElement method) {
    if (method.isPrivate) return false;
    Function capabilityChecker = method.isStatic
        ? capabilities.supportsStaticInvoke
        : capabilities.supportsInstanceInvoke;
    return capabilityChecker(method.name, method.metadata);
  });
}

Iterable<ParameterElement> _extractDeclaredParameters(
    Iterable<MethodElement> declaredMethods,
    Iterable<ConstructorElement> declaredConstructors,
    Iterable<PropertyAccessorElement> accessors) {
  List<ParameterElement> result = <ParameterElement>[];
  for (MethodElement declaredMethod in declaredMethods) {
    result.addAll(declaredMethod.parameters);
  }
  for (ConstructorElement declaredConstructor in declaredConstructors) {
    result.addAll(declaredConstructor.parameters);
  }
  for (PropertyAccessorElement accessor in accessors) {
    if (accessor.isSetter) {
      result.addAll(accessor.parameters);
    }
  }
  return result;
}

/// Returns the [PropertyAccessorElement]s which are the accessors
/// of the given [classElement], including both the declared ones
/// and the implicitly generated ones corresponding to fields. This
/// is the set of accessors that corresponds to the behavioral interface
/// of the corresponding instances, as opposed to the source code oriented
/// interface, e.g., `declarations`. But the latter can be computed from
/// here, by filtering out the accessors whose `isSynthetic` is true
/// and adding the fields.
Iterable<PropertyAccessorElement> _declaredAndImplicitAccessors(
    ClassElement classElement, _Capabilities capabilities) {
  return classElement.accessors.where((PropertyAccessorElement accessor) {
    if (accessor.isPrivate) return false;
    Function capabilityChecker = accessor.isStatic
        ? capabilities.supportsStaticInvoke
        : capabilities.supportsInstanceInvoke;
    return capabilityChecker(accessor.name, accessor.metadata);
  });
}

Iterable<ConstructorElement> _declaredConstructors(
    ClassElement classElement, _Capabilities capabilities) {
  return classElement.constructors.where((ConstructorElement constructor) {
    if (constructor.isPrivate) return false;
    return capabilities.supportsNewInstance(
        constructor.name, constructor.metadata);
  });
}

_ClassDomain _createClassDomain(ClassElement type, _ReflectorDomain domain) {
  if (type is MixinApplication) {
    List<FieldElement> declaredFieldsOfClass =
        _extractDeclaredFields(type.mixin, domain._capabilities)
            .where((FieldElement e) => !e.isStatic)
            .toList();
    List<MethodElement> declaredMethodsOfClass =
        _extractDeclaredMethods(type.mixin, domain._capabilities)
            .where((MethodElement e) => !e.isStatic)
            .toList();
    List<PropertyAccessorElement> declaredAndImplicitAccessorsOfClass =
        _declaredAndImplicitAccessors(type.mixin, domain._capabilities)
            .toList();
    List<ConstructorElement> declaredConstructorsOfClass =
        new List<ConstructorElement>();
    List<ParameterElement> declaredParametersOfClass =
        _extractDeclaredParameters(declaredMethodsOfClass,
            declaredConstructorsOfClass, declaredAndImplicitAccessorsOfClass);

    return new _ClassDomain(
        type,
        declaredFieldsOfClass,
        declaredMethodsOfClass,
        declaredParametersOfClass,
        declaredAndImplicitAccessorsOfClass,
        declaredConstructorsOfClass,
        domain);
  }

  List<FieldElement> declaredFieldsOfClass =
      _extractDeclaredFields(type, domain._capabilities).toList();
  List<MethodElement> declaredMethodsOfClass =
      _extractDeclaredMethods(type, domain._capabilities).toList();
  List<PropertyAccessorElement> declaredAndImplicitAccessorsOfClass =
      _declaredAndImplicitAccessors(type, domain._capabilities).toList();
  List<ConstructorElement> declaredConstructorsOfClass =
      _declaredConstructors(type, domain._capabilities).toList();
  List<ParameterElement> declaredParametersOfClass = _extractDeclaredParameters(
      declaredMethodsOfClass,
      declaredConstructorsOfClass,
      declaredAndImplicitAccessorsOfClass);
  return new _ClassDomain(
      type,
      declaredFieldsOfClass,
      declaredMethodsOfClass,
      declaredParametersOfClass,
      declaredAndImplicitAccessorsOfClass,
      declaredConstructorsOfClass,
      domain);
}

/// Answers true iff [element] can be imported into [generatedLibraryId].
// TODO(sigurdm) implement: Make a test that tries to reflect on native/private
// classes.
bool _isImportable(
    Element element, AssetId generatedLibraryId, Resolver resolver) {
  return !element.isPrivate &&
      _isImportableLibrary(element.library, generatedLibraryId, resolver);
}

/// Answers true iff [library] can be imported into [generatedLibraryId].
bool _isImportableLibrary(
    LibraryElement library, AssetId generatedLibraryId, Resolver resolver) {
  Uri importUri = resolver.getImportUri(library, from: generatedLibraryId);
  return importUri.scheme != "dart" || sdkLibraryNames.contains(importUri.path);
}

/// Modelling a mixin application as a [ClassElement].
///
/// We need to model mixin applications separately, because the analyzer uses
/// a model where the superclass (that is, `ClassElement.supertype`) is the
/// syntactic superclass (for `class C extends B with M..` it is `B`, not the
/// mixin application `B with M`) rather than the semantic one (`B with M`).
/// The [declaredName] is used in the case `class B = A with M..;` in
/// which case it is `B`; with other mixin applications it is [null].
/// We model the superclass of this mixin application with [superclass],
/// which may be a regular [ClassElement] or a [MixinApplication]; the
/// [mixin] is the class which was applied as a mixin to create this mixin
/// application; the [library] is the enclosing library of the mixin
/// application; and the [subclass] is the class `C` that caused this mixin
/// application to be created because it is the immediate superclass of `C`;
/// [subclass] is only use when it is _not_ a [MixinApplication], so when it
/// would have been a [MixinApplication] it is left as [null].
///
/// This class is only used to mark the synthetic mixin application classes,
/// so most of the class is left unimplemented.
class MixinApplication implements ClassElement {
  final String declaredName;
  final ClassElement superclass;
  final ClassElement mixin;
  final LibraryElement library;
  final ClassElement subclass;

  MixinApplication(this.declaredName, this.superclass, this.mixin, this.library,
      this.subclass);

  @override
  String get name {
    if (declaredName != null) return declaredName;
    if (superclass is MixinApplication) {
      return "${superclass.name}, ${_qualifiedName(mixin)}";
    } else {
      return "${_qualifiedName(superclass)} with ${_qualifiedName(mixin)}";
    }
  }

  @override
  List<InterfaceType> get interfaces => <InterfaceType>[];

  @override
  List<ElementAnnotation> get metadata => <ElementAnnotation>[];

  @override
  bool get isSynthetic => true;

  @override
  InterfaceType get supertype {
    if (superclass is MixinApplication) return superclass.supertype;
    return superclass?.type;
  }

  @override
  InterfaceType get type => mixin.type;

  @override
  List<InterfaceType> get mixins {
    List<InterfaceType> result = <InterfaceType>[];
    if (superclass != null && superclass is MixinApplication) {
      result.addAll(superclass.mixins);
    }
    result.add(mixin.type);
    return result;
  }

  /// Returns true iff this class was declared using the syntax
  /// `class B = A with M;`, i.e., if it is an explicitly named mixin
  /// application. We do not create instances of this class in that
  /// case.
  @override
  bool get isMixinApplication => declaredName != null;

  @override
  bool operator ==(Object object) {
    return object is MixinApplication &&
        superclass == object.superclass &&
        mixin == object.mixin &&
        library == object.library &&
        subclass == object.subclass;
  }

  @override
  int get hashCode => superclass.hashCode ^ mixin.hashCode ^ library.hashCode;

  toString() => "MixinApplication($superclass, $mixin)";

  _unImplemented() => throw new UnimplementedError();

  @override
  List<PropertyAccessorElement> get accessors => _unImplemented();

  @override
  List<InterfaceType> get allSupertypes => _unImplemented();

  @override
  List<ConstructorElement> get constructors => _unImplemented();

  @override
  List<FieldElement> get fields => _unImplemented();

  @override
  bool get hasNonFinalField => _unImplemented();

  @override
  bool get hasReferenceToSuper => _unImplemented();

  @override
  bool get hasStaticMember => _unImplemented();

  @override
  bool get isAbstract => _unImplemented();

  @override
  bool get isEnum => _unImplemented();

  @override
  bool get isOrInheritsProxy => _unImplemented();

  @override
  bool get isProxy => _unImplemented();

  @override
  bool get isTypedef => _unImplemented();

  @override
  bool get isValidMixin => _unImplemented();

  @override
  List<MethodElement> get methods => _unImplemented();

  @override
  List<TypeParameterElement> get typeParameters => _unImplemented();

  @override
  ConstructorElement get unnamedConstructor => _unImplemented();

  @override
  NamedCompilationUnitMember computeNode() => _unImplemented();

  @override
  FieldElement getField(String name) => _unImplemented();

  @override
  PropertyAccessorElement getGetter(String name) => _unImplemented();

  @override
  MethodElement getMethod(String name) => _unImplemented();

  @override
  ConstructorElement getNamedConstructor(String name) => _unImplemented();

  @override
  PropertyAccessorElement getSetter(String name) => _unImplemented();

  @override
  bool isSuperConstructorAccessible(ConstructorElement constructor) {
    return _unImplemented();
  }

  @override
  MethodElement lookUpConcreteMethod(
      String methodName, LibraryElement library) {
    return _unImplemented();
  }

  @override
  PropertyAccessorElement lookUpGetter(
      String getterName, LibraryElement library) {
    return _unImplemented();
  }

  @override
  PropertyAccessorElement lookUpInheritedConcreteGetter(
      String getterName, LibraryElement library) {
    return _unImplemented();
  }

  @override
  MethodElement lookUpInheritedConcreteMethod(
      String methodName, LibraryElement library) {
    return _unImplemented();
  }

  @override
  PropertyAccessorElement lookUpInheritedConcreteSetter(
      String setterName, LibraryElement library) {
    return _unImplemented();
  }

  @override
  MethodElement lookUpInheritedMethod(
      String methodName, LibraryElement library) {
    return _unImplemented();
  }

  @override
  MethodElement lookUpMethod(String methodName, LibraryElement library) {
    return _unImplemented();
  }

  @override
  PropertyAccessorElement lookUpSetter(
      String setterName, LibraryElement library) {
    return _unImplemented();
  }

  // This seems to be the defined behaviour according to dart:mirrors.
  @override
  bool get isPrivate => false;

  @override
  get context => _unImplemented();

  @override
  String get displayName => _unImplemented();

  @override
  Element get enclosingElement => _unImplemented();

  @override
  int get id => _unImplemented();

  @override
  bool get isDeprecated => _unImplemented();

  @override
  bool get isOverride => _unImplemented();

  @override
  bool get isPublic => _unImplemented();

  @override
  ElementKind get kind => _unImplemented();

  @override
  ElementLocation get location => _unImplemented();

  @override
  int get nameOffset => _unImplemented();

  @override
  AstNode get node => _unImplemented();

  @override
  get source => _unImplemented();

  @override
  CompilationUnit get unit => _unImplemented();

  @override
  accept(ElementVisitor visitor) => _unImplemented();

  @override
  String computeDocumentationComment() => _unImplemented();

  @override
  Element getAncestor(predicate) => _unImplemented();

  @override
  String getExtendedDisplayName(String shortName) => _unImplemented();

  @override
  bool isAccessibleIn(LibraryElement library) => _unImplemented();

  @override
  void visitChildren(ElementVisitor visitor) => _unImplemented();
}

String _qualifiedName(ClassElement classElement) {
  return classElement == null
      ? "null"
      : "${classElement.library.name}.${classElement.name}";
}
