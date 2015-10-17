// Copyright (c) 2015, <your name>. All rights reserved. Use of this source code
// is governed by a BSD-style license that can be found in the LICENSE file.


void main() {
  var langs = <String>['Python','ruby','java'];
  var langs2= new List<String>();
  langs2.add('python');
  langs2.add('ruby');
  langs2.add('dart');
//  langs2.add(42);
  var listofString = new List<List<String>>();

  var map = new Map<int, String>();
  map[1]='dart';
  map[2]='java';
  map[3]='javascript';
  print('$map');
  map['four']='perl';
}
