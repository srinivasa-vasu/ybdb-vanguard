/*******************************************************************************
   Chinook Database — Oracle Free compatible version
   Schema: SYSTEM (default schema for the demo)
   Syntax: Oracle 21c / Oracle Free  (IDENTITY, VARCHAR2, NUMBER)
********************************************************************************/

-- Drop tables if they exist from a previous run
BEGIN
  EXECUTE IMMEDIATE 'DROP TABLE "InvoiceLine" CASCADE CONSTRAINTS'; EXCEPTION WHEN OTHERS THEN NULL;
END;
/
BEGIN
  EXECUTE IMMEDIATE 'DROP TABLE "Invoice" CASCADE CONSTRAINTS'; EXCEPTION WHEN OTHERS THEN NULL;
END;
/
BEGIN
  EXECUTE IMMEDIATE 'DROP TABLE "Track" CASCADE CONSTRAINTS'; EXCEPTION WHEN OTHERS THEN NULL;
END;
/
BEGIN
  EXECUTE IMMEDIATE 'DROP TABLE "PlaylistTrack" CASCADE CONSTRAINTS'; EXCEPTION WHEN OTHERS THEN NULL;
END;
/
BEGIN
  EXECUTE IMMEDIATE 'DROP TABLE "Playlist" CASCADE CONSTRAINTS'; EXCEPTION WHEN OTHERS THEN NULL;
END;
/
BEGIN
  EXECUTE IMMEDIATE 'DROP TABLE "Customer" CASCADE CONSTRAINTS'; EXCEPTION WHEN OTHERS THEN NULL;
END;
/
BEGIN
  EXECUTE IMMEDIATE 'DROP TABLE "Employee" CASCADE CONSTRAINTS'; EXCEPTION WHEN OTHERS THEN NULL;
END;
/
BEGIN
  EXECUTE IMMEDIATE 'DROP TABLE "Album" CASCADE CONSTRAINTS'; EXCEPTION WHEN OTHERS THEN NULL;
END;
/
BEGIN
  EXECUTE IMMEDIATE 'DROP TABLE "Artist" CASCADE CONSTRAINTS'; EXCEPTION WHEN OTHERS THEN NULL;
END;
/
BEGIN
  EXECUTE IMMEDIATE 'DROP TABLE "Genre" CASCADE CONSTRAINTS'; EXCEPTION WHEN OTHERS THEN NULL;
END;
/
BEGIN
  EXECUTE IMMEDIATE 'DROP TABLE "MediaType" CASCADE CONSTRAINTS'; EXCEPTION WHEN OTHERS THEN NULL;
END;
/

/*******************************************************************************
   Create Tables
********************************************************************************/

CREATE TABLE "Genre"
(
    "GenreId"   NUMBER(10) GENERATED ALWAYS AS IDENTITY NOT NULL,
    "Name"      VARCHAR2(120),
    CONSTRAINT "PK_Genre" PRIMARY KEY ("GenreId")
);

CREATE TABLE "MediaType"
(
    "MediaTypeId"   NUMBER(10) GENERATED ALWAYS AS IDENTITY NOT NULL,
    "Name"          VARCHAR2(120),
    CONSTRAINT "PK_MediaType" PRIMARY KEY ("MediaTypeId")
);

CREATE TABLE "Artist"
(
    "ArtistId"  NUMBER(10) GENERATED ALWAYS AS IDENTITY NOT NULL,
    "Name"      VARCHAR2(120),
    CONSTRAINT "PK_Artist" PRIMARY KEY ("ArtistId")
);

CREATE TABLE "Album"
(
    "AlbumId"   NUMBER(10) GENERATED ALWAYS AS IDENTITY NOT NULL,
    "Title"     VARCHAR2(160)   NOT NULL,
    "ArtistId"  NUMBER(10)      NOT NULL,
    CONSTRAINT "PK_Album" PRIMARY KEY ("AlbumId"),
    CONSTRAINT "FK_AlbumArtistId" FOREIGN KEY ("ArtistId") REFERENCES "Artist" ("ArtistId")
);

CREATE TABLE "Track"
(
    "TrackId"       NUMBER(10) GENERATED ALWAYS AS IDENTITY NOT NULL,
    "Name"          VARCHAR2(200)   NOT NULL,
    "AlbumId"       NUMBER(10),
    "MediaTypeId"   NUMBER(10)      NOT NULL,
    "GenreId"       NUMBER(10),
    "Composer"      VARCHAR2(220),
    "Milliseconds"  NUMBER(10)      NOT NULL,
    "Bytes"         NUMBER(10),
    "UnitPrice"     NUMBER(10,2)    NOT NULL,
    CONSTRAINT "PK_Track" PRIMARY KEY ("TrackId"),
    CONSTRAINT "FK_TrackAlbumId"     FOREIGN KEY ("AlbumId")     REFERENCES "Album"     ("AlbumId"),
    CONSTRAINT "FK_TrackGenreId"     FOREIGN KEY ("GenreId")     REFERENCES "Genre"     ("GenreId"),
    CONSTRAINT "FK_TrackMediaTypeId" FOREIGN KEY ("MediaTypeId") REFERENCES "MediaType" ("MediaTypeId")
);

CREATE TABLE "Employee"
(
    "EmployeeId"    NUMBER(10) GENERATED ALWAYS AS IDENTITY NOT NULL,
    "LastName"      VARCHAR2(20)    NOT NULL,
    "FirstName"     VARCHAR2(20)    NOT NULL,
    "Title"         VARCHAR2(30),
    "ReportsTo"     NUMBER(10),
    "BirthDate"     DATE,
    "HireDate"      DATE,
    "Address"       VARCHAR2(70),
    "City"          VARCHAR2(40),
    "State"         VARCHAR2(40),
    "Country"       VARCHAR2(40),
    "PostalCode"    VARCHAR2(10),
    "Phone"         VARCHAR2(24),
    "Fax"           VARCHAR2(24),
    "Email"         VARCHAR2(60),
    CONSTRAINT "PK_Employee" PRIMARY KEY ("EmployeeId"),
    CONSTRAINT "FK_EmployeeReportsTo" FOREIGN KEY ("ReportsTo") REFERENCES "Employee" ("EmployeeId")
);

CREATE TABLE "Customer"
(
    "CustomerId"    NUMBER(10) GENERATED ALWAYS AS IDENTITY NOT NULL,
    "FirstName"     VARCHAR2(40)    NOT NULL,
    "LastName"      VARCHAR2(20)    NOT NULL,
    "Company"       VARCHAR2(80),
    "Address"       VARCHAR2(70),
    "City"          VARCHAR2(40),
    "State"         VARCHAR2(40),
    "Country"       VARCHAR2(40),
    "PostalCode"    VARCHAR2(10),
    "Phone"         VARCHAR2(24),
    "Fax"           VARCHAR2(24),
    "Email"         VARCHAR2(60)    NOT NULL,
    "SupportRepId"  NUMBER(10),
    CONSTRAINT "PK_Customer" PRIMARY KEY ("CustomerId"),
    CONSTRAINT "FK_CustomerSupportRepId" FOREIGN KEY ("SupportRepId") REFERENCES "Employee" ("EmployeeId")
);

CREATE TABLE "Invoice"
(
    "InvoiceId"         NUMBER(10) GENERATED ALWAYS AS IDENTITY NOT NULL,
    "CustomerId"        NUMBER(10)      NOT NULL,
    "InvoiceDate"       DATE            NOT NULL,
    "BillingAddress"    VARCHAR2(70),
    "BillingCity"       VARCHAR2(40),
    "BillingState"      VARCHAR2(40),
    "BillingCountry"    VARCHAR2(40),
    "BillingPostalCode" VARCHAR2(10),
    "Total"             NUMBER(10,2)    NOT NULL,
    CONSTRAINT "PK_Invoice" PRIMARY KEY ("InvoiceId"),
    CONSTRAINT "FK_InvoiceCustomerId" FOREIGN KEY ("CustomerId") REFERENCES "Customer" ("CustomerId")
);

CREATE TABLE "InvoiceLine"
(
    "InvoiceLineId" NUMBER(10) GENERATED ALWAYS AS IDENTITY NOT NULL,
    "InvoiceId"     NUMBER(10)      NOT NULL,
    "TrackId"       NUMBER(10)      NOT NULL,
    "UnitPrice"     NUMBER(10,2)    NOT NULL,
    "Quantity"      NUMBER(10)      NOT NULL,
    CONSTRAINT "PK_InvoiceLine" PRIMARY KEY ("InvoiceLineId"),
    CONSTRAINT "FK_InvoiceLineInvoiceId" FOREIGN KEY ("InvoiceId") REFERENCES "Invoice" ("InvoiceId"),
    CONSTRAINT "FK_InvoiceLineTrackId"   FOREIGN KEY ("TrackId")   REFERENCES "Track"   ("TrackId")
);

CREATE TABLE "Playlist"
(
    "PlaylistId"    NUMBER(10) GENERATED ALWAYS AS IDENTITY NOT NULL,
    "Name"          VARCHAR2(120),
    CONSTRAINT "PK_Playlist" PRIMARY KEY ("PlaylistId")
);

CREATE TABLE "PlaylistTrack"
(
    "PlaylistId"    NUMBER(10)  NOT NULL,
    "TrackId"       NUMBER(10)  NOT NULL,
    CONSTRAINT "PK_PlaylistTrack" PRIMARY KEY ("PlaylistId", "TrackId"),
    CONSTRAINT "FK_PlaylistTrackPlaylistId" FOREIGN KEY ("PlaylistId") REFERENCES "Playlist" ("PlaylistId"),
    CONSTRAINT "FK_PlaylistTrackTrackId"    FOREIGN KEY ("TrackId")    REFERENCES "Track"    ("TrackId")
);

/*******************************************************************************
   Seed Data — representative subset of the Chinook music store
********************************************************************************/

INSERT INTO "Genre" ("Name") VALUES ('Rock');
INSERT INTO "Genre" ("Name") VALUES ('Jazz');
INSERT INTO "Genre" ("Name") VALUES ('Metal');
INSERT INTO "Genre" ("Name") VALUES ('Alternative & Punk');
INSERT INTO "Genre" ("Name") VALUES ('Classical');

INSERT INTO "MediaType" ("Name") VALUES ('MPEG audio file');
INSERT INTO "MediaType" ("Name") VALUES ('AAC audio file');
INSERT INTO "MediaType" ("Name") VALUES ('Protected AAC audio file');

INSERT INTO "Artist" ("Name") VALUES ('AC/DC');
INSERT INTO "Artist" ("Name") VALUES ('Accept');
INSERT INTO "Artist" ("Name") VALUES ('Aerosmith');
INSERT INTO "Artist" ("Name") VALUES ('Alanis Morissette');
INSERT INTO "Artist" ("Name") VALUES ('Alice In Chains');
INSERT INTO "Artist" ("Name") VALUES ('Miles Davis');
INSERT INTO "Artist" ("Name") VALUES ('The Beatles');
INSERT INTO "Artist" ("Name") VALUES ('Led Zeppelin');

INSERT INTO "Album" ("Title", "ArtistId") VALUES ('For Those About To Rock We Salute You', 1);
INSERT INTO "Album" ("Title", "ArtistId") VALUES ('Balls to the Wall', 2);
INSERT INTO "Album" ("Title", "ArtistId") VALUES ('Restless and Wild', 2);
INSERT INTO "Album" ("Title", "ArtistId") VALUES ('Let There Be Rock', 1);
INSERT INTO "Album" ("Title", "ArtistId") VALUES ('Kind Of Blue', 6);
INSERT INTO "Album" ("Title", "ArtistId") VALUES ('Abbey Road', 7);
INSERT INTO "Album" ("Title", "ArtistId") VALUES ('Physical Graffiti', 8);

INSERT INTO "Track" ("Name", "AlbumId", "MediaTypeId", "GenreId", "Composer", "Milliseconds", "Bytes", "UnitPrice")
VALUES ('For Those About To Rock (We Salute You)', 1, 1, 1, 'Angus Young, Malcolm Young, Brian Johnson', 343719, 11170334, 0.99);
INSERT INTO "Track" ("Name", "AlbumId", "MediaTypeId", "GenreId", "Composer", "Milliseconds", "Bytes", "UnitPrice")
VALUES ('Balls to the Wall', 2, 2, 1, NULL, 342562, 5510424, 0.99);
INSERT INTO "Track" ("Name", "AlbumId", "MediaTypeId", "GenreId", "Composer", "Milliseconds", "Bytes", "UnitPrice")
VALUES ('Fast As a Shark', 3, 2, 1, 'F. Baltes, S. Kaufman, U. Dirkscneider & W. Hoffman', 230619, 3990994, 0.99);
INSERT INTO "Track" ("Name", "AlbumId", "MediaTypeId", "GenreId", "Composer", "Milliseconds", "Bytes", "UnitPrice")
VALUES ('Let There Be Rock', 4, 1, 1, 'AC/DC', 366654, 12021261, 0.99);
INSERT INTO "Track" ("Name", "AlbumId", "MediaTypeId", "GenreId", "Milliseconds", "Bytes", "UnitPrice")
VALUES ('So What', 5, 1, 2, 565599, 9532295, 0.99);
INSERT INTO "Track" ("Name", "AlbumId", "MediaTypeId", "GenreId", "Milliseconds", "Bytes", "UnitPrice")
VALUES ('Come Together', 6, 1, 1, 259947, 4333664, 0.99);
INSERT INTO "Track" ("Name", "AlbumId", "MediaTypeId", "GenreId", "Milliseconds", "Bytes", "UnitPrice")
VALUES ('Something', 6, 1, 1, 183031, 3216031, 0.99);
INSERT INTO "Track" ("Name", "AlbumId", "MediaTypeId", "GenreId", "Milliseconds", "Bytes", "UnitPrice")
VALUES ('Kashmir', 7, 1, 1, 515123, 10000000, 0.99);

COMMIT;
