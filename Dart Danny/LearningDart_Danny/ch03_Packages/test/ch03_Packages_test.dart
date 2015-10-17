// Copyright (c) 2015, <your name>. All rights reserved. Use of this source code
// is governed by a BSD-style license that can be found in the LICENSE file.

library ch03_Packages.test;

import 'package:ch03_Packages/ch03_Packages.dart';
import 'package:test/test.dart';

void main() {


  print("    hello".replaceAll(" ","1"));

  group('A group of tests', () {
    Awesome awesome;

    setUp(() {
      awesome = new Awesome();
    });

    test('First Test', () {
      expect(awesome.isAwesome, isTrue);
    });
  });
}
