DROP TABLE person;
CREATE TABLE person (
 id INTEGER PRIMARY KEY AUTOINCREMENT,
 firstname,
 lastname
);

DROP TABLE cars;
CREATE TABLE cars (
id INTEGER PRIMARY KEY,
colour,
person_id
);
