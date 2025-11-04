#!/bin/bash

echo
echo To access website:
echo
echo           http://localhost:8000/work.html
echo
echo To stop server:
echo
echo           ps -eaf | grep http.server
echo
echo           kill 9999 - second number
echo

python3 -m http.server 
