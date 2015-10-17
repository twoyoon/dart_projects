// Copyright (c) 2015, Dando Yooniverse. All rights reserved. Use of this source code

// is governed by a BSD-style license that can be found in the LICENSE file.

import 'dart:html';

InputElement task;
UListElement list;

void main() {
  task = querySelector("#task")
    ..onChange.listen((e) => addItem());
  list = querySelector("#list");
[1,2,3,4,5].where((n)=> n % 2 == 1).toList();
}

void addItem() {
  var newTask = new LIElement();
  newTask.text = task.value;
  task.value = '';
  list.children.add(newTask);
}

