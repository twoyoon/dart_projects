// Copyright (c) 2015, <your name>. All rights reserved. Use of this source code

// is governed by a BSD-style license that can be found in the LICENSE file.

//import 'dart:html';

void main() {
var ba = new BankAccount("John Gates","0734-09238",1000.0);
  print("Initial balance:\t\t${ba.balance} \$");
  ba.deposit(250.0);
  print("Balance after deposit:\t\t${ba.balance} \$");
  ba.withdraw(100.0);
  print("Balance after withdraw:\t\t${ba.balance} \$");
}

class BankAccount {
  String owner, number;
  double balance;

  //constructor
  BankAccount(this.owner, this.number, this.balance);

  //methods
  deposit(double amount) => balance += amount;

  withdraw(double amount) => balance -= amount;
}