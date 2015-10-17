// Copyright (c) 2015, <your name>. All rights reserved. Use of this source code

// is governed by a BSD-style license that can be found in the LICENSE file.

import 'dart:html';
import 'dart:async';
import 'dart:convert';

JsonDecoder decode = new JsonDecoder();

Element output;
Element jsonout;

void main() {
  jsonout=querySelector('#jsonout');
  output= querySelector('#output')
    ..text = 'Your Dart app is running.'
    ..style.color = "red"
    ..onClick.listen((e) => print("Mouse clicked"));

  new Timer.periodic(new Duration(seconds: 4), timerCallback);
}

timerCallback(Timer t) {
  loadUrl();
}

loadUrl() async {
  var result = await HttpRequest.getString(
      "https://api.particle.io/v1/devices/250043001247343339383037/state?access_token=09c3f35b49c3b25a5f860c60534c71b5016f76ea");
  Map m = decode.convert(result);
  output.text= "The Garage is " + m["result"];
  jsonout.text = result;
}