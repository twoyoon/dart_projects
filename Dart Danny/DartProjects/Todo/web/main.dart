// Copyright (c) 2015, <your name>. All rights reserved. Use of this source code

// is governed by a BSD-style license that can be found in the LICENSE file.

import 'dart:html';

InputElement toDoInput;
UListElement toDoList;
ButtonElement deleteAll;

void main() {
  deleteAll = querySelector("#delete-all");
  deleteAll.onClick.listen((e) => toDoList.children.clear());


  toDoInput = querySelector("#to-do-input");
  toDoList = querySelector("#to-do-list");
  toDoInput.onChange.listen(addToDoItem);
  addManyTodos();
}

void addToDoItem(Event e) {
  if (window.confirm("Item Added!!")) {
    print("Confirmed!!!!");
    var newToDo = new LIElement();
    newToDo.text = toDoInput.value;
    newToDo.onClick.listen(removeline);
    toDoInput.value = '';
    toDoList.children.add(newToDo);
  } else {
    print("Cancellled!!!");
  }
}


addManyTodos() {
  for (int i = 0; i < 20; i++) {
    var newTodo = new LIElement();
    newTodo.text = "All work and no play " + i.toString();
    newTodo.onClick.listen((e) => newTodo.remove());
    toDoList.children.add(newTodo);
  }
}

//todo:
removeline(Event e) {
  Element target = e.target;
  if (window.confirm("Are you sure you want to delete!!!!")) {
    print("Confirmed!!!!");
    target.remove();
  } else {
    print("Cancellled!!!");
  }
}