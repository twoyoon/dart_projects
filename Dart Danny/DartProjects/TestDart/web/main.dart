// Copyright (c) 2015, <your name>. All rights reserved. Use of this source code

// is governed by a BSD-style license that can be found in the LICENSE file.

import 'dart:async';
import 'dart:html';

bool COLOR = true;

void main() {
  toggleColor();
}

toggleColor() {
  new Timer.periodic(const Duration(milliseconds: 500), (Timer t) {
    if (COLOR == true) {
      querySelector('#output').innerHtml =
          '<h1><font color="blue">hey...Your Dart app is running.';
      COLOR = false;
    } else {
      querySelector('#output').innerHtml =
          '<h1><font color="green">hey...Your Dart app is running.';
      COLOR = true;
    }
  });
}
