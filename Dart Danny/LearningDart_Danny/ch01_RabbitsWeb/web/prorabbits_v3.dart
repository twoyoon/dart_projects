// Copyright (c) 2015, <your name>. All rights reserved. Use of this source code

// is governed by a BSD-style license that can be found in the LICENSE file.

import 'dart:html';
import 'dart:math';

void main() {
  querySelector("#submit").onClick.listen((e) => calcRabbits());
}


calcRabbits() {
  //bind vars to html elements
  InputElement yearsInput = querySelector("#years");
  LabelElement output = querySelector("#output");
  //getting input
  String yearsString = yearsInput.value;
  int years = int.parse(yearsString);
  //calc
  output.innerHtml = "<h1>${calculateRabbits(years)}</h1>";

}

calculateRabbits(years) {
  return (2*pow(E,log(15)*years)).round().toInt();
}
