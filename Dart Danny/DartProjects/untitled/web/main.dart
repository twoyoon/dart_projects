// Copyright (c) 2015, <your name>. All rights reserved. Use of this source code

// is governed by a BSD-style license that can be found in the LICENSE file.

import 'dart:html';
import 'dart:math';

//Should remove tiles from here when they are selected otherwise the ration is off

String scabbleLetters = 'aaaaaaaaabbccddddeeeeeeeeeeeeffggghhiiiiiiiiijkllllmmnnnnnnooooooooppqrrrrrrssssttttttuuuuvvwwxyyz**';

List<ButtonElement> buttons = new List();
List colors = [ "red","yellow","orange","green","blue","magenta","purple"];

Element letterpile;
Element result;
ButtonElement clearButton;
Element value;
int wordvalue = 0;

Map scrabbleValues = { 'a':1, 'e':1, 'i':1, 'l':1, 'n':1,
  'o':1, 'r':1, 's':1, 't':1, 'u':1,
  'd':2, 'g':2, 'b':3, 'c':3, 'm':3,
  'p':3, 'f':4, 'h':4, 'v':4, 'w':4,
  'y':4, 'k':5, 'j':8, 'x':8, 'q':10,
  'z':10, '*':0};

void main() {
  letterpile = querySelector("#letterpile");
  result = querySelector("#result");
  value = querySelector("#value");

  clearButton = querySelector("#clearButton");
  clearButton.onClick.listen(newletters);

  generateNewLetters();
}

newletters(Event e) {
  letterpile.children.clear();
  result.children.clear();
  generateNewLetters();
}

generateNewLetters() {
  Random indexGenerator = new Random();
  wordvalue = 0;
  value.text = '';
  buttons.clear();
  for (int i = 0; i < 7; i++) {
    int letterIndex = indexGenerator.nextInt(scabbleLetters.length);

    //should remove the letter from scrabble letters to keep ratio
    buttons.add(new ButtonElement());
    buttons[i].classes.add("letter");
    buttons[i].onClick.listen(moveLetter);
    buttons[i].style.color = "black";
    buttons[i].style.backgroundColor = colors[i];

    buttons[i].text = scabbleLetters[letterIndex];
    letterpile.children.add(buttons[i]);
  }
}


moveLetter(Event e) {
  Element letter = e.target;
  if (letter.parent == letterpile) {
    result.children.add(letter);
    wordvalue += scrabbleValues[letter.text];
    value.text = "$wordvalue";
  }
}