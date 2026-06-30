/*******************************************************************************
   Chinook Database — SQL Server T-SQL version

   Differences from PostgreSQL version:
     - TIMESTAMP → DATETIME2
     - No SERIAL — IDs are supplied explicitly in INSERTs
     - CREATE INDEX uses T-SQL syntax (same as PostgreSQL for this schema)
     - Wrapped in a USE statement; caller must create the database first.
********************************************************************************/

USE [chinook];
GO

/*******************************************************************************
   Create Tables
********************************************************************************/
CREATE TABLE Album
(
    AlbumId INT NOT NULL,
    Title VARCHAR(160) NOT NULL,
    ArtistId INT NOT NULL,
    CONSTRAINT PK_Album PRIMARY KEY (AlbumId)
);
GO

CREATE TABLE Artist
(
    ArtistId INT NOT NULL,
    Name VARCHAR(120),
    CONSTRAINT PK_Artist PRIMARY KEY (ArtistId)
);
GO

CREATE TABLE Customer
(
    CustomerId INT NOT NULL,
    FirstName VARCHAR(40) NOT NULL,
    LastName VARCHAR(20) NOT NULL,
    Company VARCHAR(80),
    Address VARCHAR(70),
    City VARCHAR(40),
    State VARCHAR(40),
    Country VARCHAR(40),
    PostalCode VARCHAR(10),
    Phone VARCHAR(24),
    Fax VARCHAR(24),
    Email VARCHAR(60) NOT NULL,
    SupportRepId INT,
    CONSTRAINT PK_Customer PRIMARY KEY (CustomerId)
);
GO

CREATE TABLE Employee
(
    EmployeeId INT NOT NULL,
    LastName VARCHAR(20) NOT NULL,
    FirstName VARCHAR(20) NOT NULL,
    Title VARCHAR(30),
    ReportsTo INT,
    BirthDate DATETIME2,
    HireDate DATETIME2,
    Address VARCHAR(70),
    City VARCHAR(40),
    State VARCHAR(40),
    Country VARCHAR(40),
    PostalCode VARCHAR(10),
    Phone VARCHAR(24),
    Fax VARCHAR(24),
    Email VARCHAR(60),
    CONSTRAINT PK_Employee PRIMARY KEY (EmployeeId)
);
GO

CREATE TABLE Genre
(
    GenreId INT NOT NULL,
    Name VARCHAR(120),
    CONSTRAINT PK_Genre PRIMARY KEY (GenreId)
);
GO

CREATE TABLE Invoice
(
    InvoiceId INT NOT NULL,
    CustomerId INT NOT NULL,
    InvoiceDate DATETIME2 NOT NULL,
    BillingAddress VARCHAR(70),
    BillingCity VARCHAR(40),
    BillingState VARCHAR(40),
    BillingCountry VARCHAR(40),
    BillingPostalCode VARCHAR(10),
    Total NUMERIC(10,2) NOT NULL,
    CONSTRAINT PK_Invoice PRIMARY KEY (InvoiceId)
);
GO

CREATE TABLE InvoiceLine
(
    InvoiceLineId INT NOT NULL,
    InvoiceId INT NOT NULL,
    TrackId INT NOT NULL,
    UnitPrice NUMERIC(10,2) NOT NULL,
    Quantity INT NOT NULL,
    CONSTRAINT PK_InvoiceLine PRIMARY KEY (InvoiceLineId)
);
GO

CREATE TABLE MediaType
(
    MediaTypeId INT NOT NULL,
    Name VARCHAR(120),
    CONSTRAINT PK_MediaType PRIMARY KEY (MediaTypeId)
);
GO

CREATE TABLE Playlist
(
    PlaylistId INT NOT NULL,
    Name VARCHAR(120),
    CONSTRAINT PK_Playlist PRIMARY KEY (PlaylistId)
);
GO

CREATE TABLE PlaylistTrack
(
    PlaylistId INT NOT NULL,
    TrackId INT NOT NULL,
    CONSTRAINT PK_PlaylistTrack PRIMARY KEY (PlaylistId, TrackId)
);
GO

CREATE TABLE Track
(
    TrackId INT NOT NULL,
    Name VARCHAR(200) NOT NULL,
    AlbumId INT,
    MediaTypeId INT NOT NULL,
    GenreId INT,
    Composer VARCHAR(220),
    Milliseconds INT NOT NULL,
    Bytes INT,
    UnitPrice NUMERIC(10,2) NOT NULL,
    CONSTRAINT PK_Track PRIMARY KEY (TrackId)
);
GO

/*******************************************************************************
   Create Foreign Keys
********************************************************************************/
ALTER TABLE Album ADD CONSTRAINT FK_AlbumArtistId
    FOREIGN KEY (ArtistId) REFERENCES Artist (ArtistId) ON DELETE NO ACTION ON UPDATE NO ACTION;
GO
CREATE INDEX IFK_AlbumArtistId ON Album (ArtistId);
GO

ALTER TABLE Customer ADD CONSTRAINT FK_CustomerSupportRepId
    FOREIGN KEY (SupportRepId) REFERENCES Employee (EmployeeId) ON DELETE NO ACTION ON UPDATE NO ACTION;
GO
CREATE INDEX IFK_CustomerSupportRepId ON Customer (SupportRepId);
GO

ALTER TABLE Employee ADD CONSTRAINT FK_EmployeeReportsTo
    FOREIGN KEY (ReportsTo) REFERENCES Employee (EmployeeId) ON DELETE NO ACTION ON UPDATE NO ACTION;
GO
CREATE INDEX IFK_EmployeeReportsTo ON Employee (ReportsTo);
GO

ALTER TABLE Invoice ADD CONSTRAINT FK_InvoiceCustomerId
    FOREIGN KEY (CustomerId) REFERENCES Customer (CustomerId) ON DELETE NO ACTION ON UPDATE NO ACTION;
GO
CREATE INDEX IFK_InvoiceCustomerId ON Invoice (CustomerId);
GO

ALTER TABLE InvoiceLine ADD CONSTRAINT FK_InvoiceLineInvoiceId
    FOREIGN KEY (InvoiceId) REFERENCES Invoice (InvoiceId) ON DELETE NO ACTION ON UPDATE NO ACTION;
GO
CREATE INDEX IFK_InvoiceLineInvoiceId ON InvoiceLine (InvoiceId);
GO

ALTER TABLE InvoiceLine ADD CONSTRAINT FK_InvoiceLineTrackId
    FOREIGN KEY (TrackId) REFERENCES Track (TrackId) ON DELETE NO ACTION ON UPDATE NO ACTION;
GO
CREATE INDEX IFK_InvoiceLineTrackId ON InvoiceLine (TrackId);
GO

ALTER TABLE PlaylistTrack ADD CONSTRAINT FK_PlaylistTrackPlaylistId
    FOREIGN KEY (PlaylistId) REFERENCES Playlist (PlaylistId) ON DELETE NO ACTION ON UPDATE NO ACTION;
GO
ALTER TABLE PlaylistTrack ADD CONSTRAINT FK_PlaylistTrackTrackId
    FOREIGN KEY (TrackId) REFERENCES Track (TrackId) ON DELETE NO ACTION ON UPDATE NO ACTION;
GO
CREATE INDEX IFK_PlaylistTrackTrackId ON PlaylistTrack (TrackId);
GO

ALTER TABLE Track ADD CONSTRAINT FK_TrackAlbumId
    FOREIGN KEY (AlbumId) REFERENCES Album (AlbumId) ON DELETE NO ACTION ON UPDATE NO ACTION;
GO
CREATE INDEX IFK_TrackAlbumId ON Track (AlbumId);
GO

ALTER TABLE Track ADD CONSTRAINT FK_TrackGenreId
    FOREIGN KEY (GenreId) REFERENCES Genre (GenreId) ON DELETE NO ACTION ON UPDATE NO ACTION;
GO
CREATE INDEX IFK_TrackGenreId ON Track (GenreId);
GO

ALTER TABLE Track ADD CONSTRAINT FK_TrackMediaTypeId
    FOREIGN KEY (MediaTypeId) REFERENCES MediaType (MediaTypeId) ON DELETE NO ACTION ON UPDATE NO ACTION;
GO
CREATE INDEX IFK_TrackMediaTypeId ON Track (MediaTypeId);
GO

/*******************************************************************************
   Populate Tables
********************************************************************************/
INSERT INTO Genre (GenreId, Name) VALUES (1, 'Rock');
INSERT INTO Genre (GenreId, Name) VALUES (2, 'Jazz');
INSERT INTO Genre (GenreId, Name) VALUES (3, 'Metal');
INSERT INTO Genre (GenreId, Name) VALUES (4, 'Alternative & Punk');
INSERT INTO Genre (GenreId, Name) VALUES (5, 'Rock And Roll');
INSERT INTO Genre (GenreId, Name) VALUES (6, 'Blues');
INSERT INTO Genre (GenreId, Name) VALUES (7, 'Latin');
INSERT INTO Genre (GenreId, Name) VALUES (8, 'Reggae');
INSERT INTO Genre (GenreId, Name) VALUES (9, 'Pop');
INSERT INTO Genre (GenreId, Name) VALUES (10, 'Soundtrack');
INSERT INTO Genre (GenreId, Name) VALUES (11, 'Bossa Nova');
INSERT INTO Genre (GenreId, Name) VALUES (12, 'Easy Listening');
INSERT INTO Genre (GenreId, Name) VALUES (13, 'Heavy Metal');
INSERT INTO Genre (GenreId, Name) VALUES (14, 'R&B/Soul');
INSERT INTO Genre (GenreId, Name) VALUES (15, 'Electronica/Dance');
INSERT INTO Genre (GenreId, Name) VALUES (16, 'World');
INSERT INTO Genre (GenreId, Name) VALUES (17, 'Hip Hop/Rap');
INSERT INTO Genre (GenreId, Name) VALUES (18, 'Science Fiction');
INSERT INTO Genre (GenreId, Name) VALUES (19, 'TV Shows');
INSERT INTO Genre (GenreId, Name) VALUES (20, 'Sci Fi & Fantasy');
INSERT INTO Genre (GenreId, Name) VALUES (21, 'Drama');
INSERT INTO Genre (GenreId, Name) VALUES (22, 'Comedy');
INSERT INTO Genre (GenreId, Name) VALUES (23, 'Alternative');
INSERT INTO Genre (GenreId, Name) VALUES (24, 'Classical');
INSERT INTO Genre (GenreId, Name) VALUES (25, 'Opera');
GO

INSERT INTO MediaType (MediaTypeId, Name) VALUES (1, 'MPEG audio file');
INSERT INTO MediaType (MediaTypeId, Name) VALUES (2, 'Protected AAC audio file');
INSERT INTO MediaType (MediaTypeId, Name) VALUES (3, 'Protected MPEG-4 video file');
INSERT INTO MediaType (MediaTypeId, Name) VALUES (4, 'Purchased AAC audio file');
INSERT INTO MediaType (MediaTypeId, Name) VALUES (5, 'AAC audio file');
GO

INSERT INTO Artist (ArtistId, Name) VALUES (1, 'AC/DC');
INSERT INTO Artist (ArtistId, Name) VALUES (2, 'Accept');
INSERT INTO Artist (ArtistId, Name) VALUES (3, 'Aerosmith');
INSERT INTO Artist (ArtistId, Name) VALUES (4, 'Alanis Morissette');
INSERT INTO Artist (ArtistId, Name) VALUES (5, 'Alice In Chains');
INSERT INTO Artist (ArtistId, Name) VALUES (6, 'Antônio Carlos Jobim');
INSERT INTO Artist (ArtistId, Name) VALUES (7, 'Apocalyptica');
INSERT INTO Artist (ArtistId, Name) VALUES (8, 'Audioslave');
INSERT INTO Artist (ArtistId, Name) VALUES (9, 'BackBeat');
INSERT INTO Artist (ArtistId, Name) VALUES (10, 'Billy Cobham');
INSERT INTO Artist (ArtistId, Name) VALUES (11, 'Black Label Society');
INSERT INTO Artist (ArtistId, Name) VALUES (12, 'Black Sabbath');
INSERT INTO Artist (ArtistId, Name) VALUES (13, 'Body Count');
INSERT INTO Artist (ArtistId, Name) VALUES (14, 'Bruce Dickinson');
INSERT INTO Artist (ArtistId, Name) VALUES (15, 'Buddy Guy');
INSERT INTO Artist (ArtistId, Name) VALUES (16, 'Caetano Veloso');
INSERT INTO Artist (ArtistId, Name) VALUES (17, 'Chico Buarque');
INSERT INTO Artist (ArtistId, Name) VALUES (18, 'Chico Science & Nação Zumbi');
INSERT INTO Artist (ArtistId, Name) VALUES (19, 'Cidade Negra');
INSERT INTO Artist (ArtistId, Name) VALUES (20, 'Cláudio Zoli');
INSERT INTO Artist (ArtistId, Name) VALUES (21, 'Various Artists');
INSERT INTO Artist (ArtistId, Name) VALUES (22, 'Led Zeppelin');
INSERT INTO Artist (ArtistId, Name) VALUES (23, 'Frank Zappa & Captain Beefheart');
INSERT INTO Artist (ArtistId, Name) VALUES (24, 'Marcos Valle');
INSERT INTO Artist (ArtistId, Name) VALUES (25, 'Milton Nascimento & Bebeto');
INSERT INTO Artist (ArtistId, Name) VALUES (26, 'Azymuth');
INSERT INTO Artist (ArtistId, Name) VALUES (27, 'Gilberto Gil');
INSERT INTO Artist (ArtistId, Name) VALUES (28, 'João Gilberto');
INSERT INTO Artist (ArtistId, Name) VALUES (29, 'Bebel Gilberto');
INSERT INTO Artist (ArtistId, Name) VALUES (30, 'Jorge Vercilo');
INSERT INTO Artist (ArtistId, Name) VALUES (31, 'Baby Consuelo');
INSERT INTO Artist (ArtistId, Name) VALUES (32, 'Ney Matogrosso');
INSERT INTO Artist (ArtistId, Name) VALUES (33, 'Luiz Melodia');
INSERT INTO Artist (ArtistId, Name) VALUES (34, 'Nando Reis');
INSERT INTO Artist (ArtistId, Name) VALUES (35, 'Pedro Luís & A Parede');
INSERT INTO Artist (ArtistId, Name) VALUES (36, 'O Rappa');
INSERT INTO Artist (ArtistId, Name) VALUES (37, 'Ed Motta');
INSERT INTO Artist (ArtistId, Name) VALUES (38, 'Banda Black Rio');
INSERT INTO Artist (ArtistId, Name) VALUES (39, 'Fernanda Porto');
INSERT INTO Artist (ArtistId, Name) VALUES (40, 'Os Cariocas');
INSERT INTO Artist (ArtistId, Name) VALUES (41, 'Elis Regina');
INSERT INTO Artist (ArtistId, Name) VALUES (42, 'Milton Nascimento');
INSERT INTO Artist (ArtistId, Name) VALUES (43, 'A Cor Do Som');
INSERT INTO Artist (ArtistId, Name) VALUES (44, 'Kid Abelha');
INSERT INTO Artist (ArtistId, Name) VALUES (45, 'Sandra De Sá');
INSERT INTO Artist (ArtistId, Name) VALUES (46, 'Jorge Ben');
INSERT INTO Artist (ArtistId, Name) VALUES (47, 'Hermeto Pascoal');
INSERT INTO Artist (ArtistId, Name) VALUES (48, 'Barão Vermelho');
INSERT INTO Artist (ArtistId, Name) VALUES (49, 'Edson, DJ Marky & DJ Patife Featuring Fernanda Porto');
INSERT INTO Artist (ArtistId, Name) VALUES (50, 'Metallica');
INSERT INTO Artist (ArtistId, Name) VALUES (51, 'Queen');
INSERT INTO Artist (ArtistId, Name) VALUES (52, 'Kiss');
INSERT INTO Artist (ArtistId, Name) VALUES (53, 'Spyro Gyra');
INSERT INTO Artist (ArtistId, Name) VALUES (54, 'Green Day');
INSERT INTO Artist (ArtistId, Name) VALUES (55, 'David Bowie');
INSERT INTO Artist (ArtistId, Name) VALUES (56, 'Os Mutantes');
INSERT INTO Artist (ArtistId, Name) VALUES (57, 'Deep Purple');
INSERT INTO Artist (ArtistId, Name) VALUES (58, 'Santana');
INSERT INTO Artist (ArtistId, Name) VALUES (59, 'Santana Feat. Dave Matthews');
INSERT INTO Artist (ArtistId, Name) VALUES (60, 'Santana Feat. Everlast');
INSERT INTO Artist (ArtistId, Name) VALUES (61, 'Santana Feat. Rob Thomas');
INSERT INTO Artist (ArtistId, Name) VALUES (62, 'Santana Feat. Lauryn Hill & Cee-Lo');
INSERT INTO Artist (ArtistId, Name) VALUES (63, 'Santana Feat. The Project G&B');
INSERT INTO Artist (ArtistId, Name) VALUES (64, 'Santana Feat. Maná');
INSERT INTO Artist (ArtistId, Name) VALUES (65, 'Santana Feat. Eagle-Eye Cherry');
INSERT INTO Artist (ArtistId, Name) VALUES (66, 'Santana Feat. Eric Clapton');
INSERT INTO Artist (ArtistId, Name) VALUES (67, 'Miles Davis');
INSERT INTO Artist (ArtistId, Name) VALUES (68, 'Gene Krupa');
INSERT INTO Artist (ArtistId, Name) VALUES (69, 'Toquinho & Vinícius');
INSERT INTO Artist (ArtistId, Name) VALUES (70, 'Vinícius De Moraes & Baden Powell');
INSERT INTO Artist (ArtistId, Name) VALUES (71, 'Vinícius De Moraes');
INSERT INTO Artist (ArtistId, Name) VALUES (72, 'Vinícius E Qurteto Em Cy');
INSERT INTO Artist (ArtistId, Name) VALUES (73, 'Vinícius E Odette Lara');
INSERT INTO Artist (ArtistId, Name) VALUES (74, 'Vinicius, Toquinho & Quarteto Em Cy');
INSERT INTO Artist (ArtistId, Name) VALUES (75, 'Creedence Clearwater Revival');
INSERT INTO Artist (ArtistId, Name) VALUES (76, 'Cássia Eller');
INSERT INTO Artist (ArtistId, Name) VALUES (77, 'Def Leppard');
INSERT INTO Artist (ArtistId, Name) VALUES (78, 'Dennis Chambers');
INSERT INTO Artist (ArtistId, Name) VALUES (79, 'Djavan');
INSERT INTO Artist (ArtistId, Name) VALUES (80, 'Eric Clapton');
INSERT INTO Artist (ArtistId, Name) VALUES (81, 'Faith No More');
INSERT INTO Artist (ArtistId, Name) VALUES (82, 'Falamansa');
INSERT INTO Artist (ArtistId, Name) VALUES (83, 'Foo Fighters');
INSERT INTO Artist (ArtistId, Name) VALUES (84, 'Frank Sinatra');
INSERT INTO Artist (ArtistId, Name) VALUES (85, 'Funk Como Le Gusta');
INSERT INTO Artist (ArtistId, Name) VALUES (86, 'Godsmack');
INSERT INTO Artist (ArtistId, Name) VALUES (87, 'Guns N'' Roses');
INSERT INTO Artist (ArtistId, Name) VALUES (88, 'Incognito');
INSERT INTO Artist (ArtistId, Name) VALUES (89, 'Iron Maiden');
INSERT INTO Artist (ArtistId, Name) VALUES (90, 'James Brown');
INSERT INTO Artist (ArtistId, Name) VALUES (91, 'Jamiroquai');
INSERT INTO Artist (ArtistId, Name) VALUES (92, 'JET');
INSERT INTO Artist (ArtistId, Name) VALUES (93, 'Jimi Hendrix');
INSERT INTO Artist (ArtistId, Name) VALUES (94, 'Joe Satriani');
INSERT INTO Artist (ArtistId, Name) VALUES (95, 'Joss Stone');
INSERT INTO Artist (ArtistId, Name) VALUES (96, 'Judas Priest');
INSERT INTO Artist (ArtistId, Name) VALUES (97, 'Legião Urbana');
INSERT INTO Artist (ArtistId, Name) VALUES (98, 'Lenny Kravitz');
INSERT INTO Artist (ArtistId, Name) VALUES (99, 'Lulu Santos');
INSERT INTO Artist (ArtistId, Name) VALUES (100, 'Marillion');
INSERT INTO Artist (ArtistId, Name) VALUES (101, 'Marisa Monte');
INSERT INTO Artist (ArtistId, Name) VALUES (102, 'Marvin Gaye');
INSERT INTO Artist (ArtistId, Name) VALUES (103, 'Men At Work');
INSERT INTO Artist (ArtistId, Name) VALUES (104, 'Motörhead');
INSERT INTO Artist (ArtistId, Name) VALUES (105, 'Motörhead & Girlschool');
INSERT INTO Artist (ArtistId, Name) VALUES (106, 'Mônica Marianno');
INSERT INTO Artist (ArtistId, Name) VALUES (107, 'Mötley Crüe');
INSERT INTO Artist (ArtistId, Name) VALUES (108, 'Nirvana');
INSERT INTO Artist (ArtistId, Name) VALUES (109, 'O Terço');
INSERT INTO Artist (ArtistId, Name) VALUES (110, 'Olodum');
INSERT INTO Artist (ArtistId, Name) VALUES (111, 'Os Paralamas Do Sucesso');
INSERT INTO Artist (ArtistId, Name) VALUES (112, 'Ozzy Osbourne');
INSERT INTO Artist (ArtistId, Name) VALUES (113, 'Page & Plant');
INSERT INTO Artist (ArtistId, Name) VALUES (114, 'Passengers');
INSERT INTO Artist (ArtistId, Name) VALUES (115, 'Paul D''Ianno');
INSERT INTO Artist (ArtistId, Name) VALUES (116, 'Pearl Jam');
INSERT INTO Artist (ArtistId, Name) VALUES (117, 'Peter Tosh');
INSERT INTO Artist (ArtistId, Name) VALUES (118, 'Pink Floyd');
INSERT INTO Artist (ArtistId, Name) VALUES (119, 'Planet Hemp');
INSERT INTO Artist (ArtistId, Name) VALUES (120, 'R.E.M. Feat. Kate Pearson');
INSERT INTO Artist (ArtistId, Name) VALUES (121, 'R.E.M. Feat. KRS-One');
INSERT INTO Artist (ArtistId, Name) VALUES (122, 'R.E.M.');
INSERT INTO Artist (ArtistId, Name) VALUES (123, 'Raimundos');
INSERT INTO Artist (ArtistId, Name) VALUES (124, 'Raul Seixas');
INSERT INTO Artist (ArtistId, Name) VALUES (125, 'Red Hot Chili Peppers');
INSERT INTO Artist (ArtistId, Name) VALUES (126, 'Rush');
INSERT INTO Artist (ArtistId, Name) VALUES (127, 'Simply Red');
INSERT INTO Artist (ArtistId, Name) VALUES (128, 'Skank');
INSERT INTO Artist (ArtistId, Name) VALUES (129, 'Smashing Pumpkins');
INSERT INTO Artist (ArtistId, Name) VALUES (130, 'Soundgarden');
INSERT INTO Artist (ArtistId, Name) VALUES (131, 'Stevie Ray Vaughan & Double Trouble');
INSERT INTO Artist (ArtistId, Name) VALUES (132, 'Stone Temple Pilots');
INSERT INTO Artist (ArtistId, Name) VALUES (133, 'System Of A Down');
INSERT INTO Artist (ArtistId, Name) VALUES (134, 'Terry Bozzio, Tony Levin & Steve Stevens');
INSERT INTO Artist (ArtistId, Name) VALUES (135, 'The Black Crowes');
INSERT INTO Artist (ArtistId, Name) VALUES (136, 'The Clash');
INSERT INTO Artist (ArtistId, Name) VALUES (137, 'The Cult');
INSERT INTO Artist (ArtistId, Name) VALUES (138, 'The Doors');
INSERT INTO Artist (ArtistId, Name) VALUES (139, 'The Police');
INSERT INTO Artist (ArtistId, Name) VALUES (140, 'The Rolling Stones');
INSERT INTO Artist (ArtistId, Name) VALUES (141, 'The Tea Party');
INSERT INTO Artist (ArtistId, Name) VALUES (142, 'The Who');
INSERT INTO Artist (ArtistId, Name) VALUES (143, 'Tim Maia');
INSERT INTO Artist (ArtistId, Name) VALUES (144, 'Titãs');
INSERT INTO Artist (ArtistId, Name) VALUES (145, 'Battlestar Galactica');
INSERT INTO Artist (ArtistId, Name) VALUES (146, 'Heroes');
INSERT INTO Artist (ArtistId, Name) VALUES (147, 'Lost');
INSERT INTO Artist (ArtistId, Name) VALUES (148, 'U2');
INSERT INTO Artist (ArtistId, Name) VALUES (149, 'UB40');
INSERT INTO Artist (ArtistId, Name) VALUES (150, 'Van Halen');
INSERT INTO Artist (ArtistId, Name) VALUES (151, 'Velvet Revolver');
INSERT INTO Artist (ArtistId, Name) VALUES (152, 'Whitesnake');
INSERT INTO Artist (ArtistId, Name) VALUES (153, 'Xis');
INSERT INTO Artist (ArtistId, Name) VALUES (154, 'Alanis Morissette');
INSERT INTO Artist (ArtistId, Name) VALUES (155, 'The Postal Service');
INSERT INTO Artist (ArtistId, Name) VALUES (156, 'Cake');
INSERT INTO Artist (ArtistId, Name) VALUES (157, 'A Balada do Amor Verdadeiro (Brazilian Folk Song)');
INSERT INTO Artist (ArtistId, Name) VALUES (158, 'Felicidade (Brazilian Folk Song)');
INSERT INTO Artist (ArtistId, Name) VALUES (159, 'O Boto (Brazilian Folk Song)');
INSERT INTO Artist (ArtistId, Name) VALUES (160, 'Canta, Canta Mais (Brazilian Folk Song)');
INSERT INTO Artist (ArtistId, Name) VALUES (161, 'Academy of St. Martin in the Fields & Sir Neville Marriner');
INSERT INTO Artist (ArtistId, Name) VALUES (162, 'Academy of St. Martin in the Fields Chamber Ensemble & Sir Neville Marriner');
INSERT INTO Artist (ArtistId, Name) VALUES (163, 'Berliner Philharmoniker & Hans Rosbaud');
INSERT INTO Artist (ArtistId, Name) VALUES (164, 'Berliner Philharmoniker & Herbert Von Karajan');
INSERT INTO Artist (ArtistId, Name) VALUES (165, 'Academy of St. Martin in the Fields, John Birch, Sir Neville Marriner & Sylvia McNair');
INSERT INTO Artist (ArtistId, Name) VALUES (166, 'London Symphony Orchestra & Sir Charles Mackerras');
INSERT INTO Artist (ArtistId, Name) VALUES (167, 'Barry Wordsworth & BBC Concert Orchestra');
INSERT INTO Artist (ArtistId, Name) VALUES (168, 'Academy of St. Martin in the Fields, Sir Neville Marriner & Thurston Dart');
INSERT INTO Artist (ArtistId, Name) VALUES (169, 'Itzhak Perlman');
INSERT INTO Artist (ArtistId, Name) VALUES (170, 'La Scala Opera Chorus & Orchestra');
INSERT INTO Artist (ArtistId, Name) VALUES (171, 'Royal Philharmonic Orchestra & Sir Thomas Beecham');
INSERT INTO Artist (ArtistId, Name) VALUES (172, 'Sinfonia of London, John Georgiadis & Sir Neville Marriner');
INSERT INTO Artist (ArtistId, Name) VALUES (173, 'Chicago Symphony Chorus, Chicago Symphony Orchestra & Sir Georg Solti');
INSERT INTO Artist (ArtistId, Name) VALUES (174, 'Orchestra of The Age of Enlightenment');
INSERT INTO Artist (ArtistId, Name) VALUES (175, 'Emanuel Ax, Eugene Ormandy & Philadelphia Orchestra');
INSERT INTO Artist (ArtistId, Name) VALUES (176, 'James Levine');
INSERT INTO Artist (ArtistId, Name) VALUES (177, 'Berliner Philharmoniker & Claudio Abbado');
INSERT INTO Artist (ArtistId, Name) VALUES (178, 'Anne-Sophie Mutter, Herbert Von Karajan & Wiener Philharmoniker');
INSERT INTO Artist (ArtistId, Name) VALUES (179, 'Hilary Hahn, Jeffrey Kahane, Los Angeles Chamber Orchestra & Margaret Batjer');
INSERT INTO Artist (ArtistId, Name) VALUES (180, 'Wilhelm Kempff');
INSERT INTO Artist (ArtistId, Name) VALUES (181, 'Yo-Yo Ma');
INSERT INTO Artist (ArtistId, Name) VALUES (182, 'Scholars Baroque Ensemble');
INSERT INTO Artist (ArtistId, Name) VALUES (183, 'Academy of St. Martin in the Fields & Sir Neville Marriner');
INSERT INTO Artist (ArtistId, Name) VALUES (184, 'Orchestre Révolutionnaire et Romantique & John Eliot Gardiner');
INSERT INTO Artist (ArtistId, Name) VALUES (185, 'The King''s Singers');
INSERT INTO Artist (ArtistId, Name) VALUES (186, 'Berliner Philharmoniker, Claudio Abbado & Sabine Meyer');
INSERT INTO Artist (ArtistId, Name) VALUES (187, 'Royal Concertgebouw Orchestra & Nikolaus Harnoncourt');
INSERT INTO Artist (ArtistId, Name) VALUES (188, 'Choir Of Westminster Abbey & Simon Preston');
INSERT INTO Artist (ArtistId, Name) VALUES (189, 'Michael Tilson Thomas & San Francisco Symphony');
INSERT INTO Artist (ArtistId, Name) VALUES (190, 'Chor der Wiener Staatsoper, Herbert Von Karajan & Wiener Philharmoniker');
INSERT INTO Artist (ArtistId, Name) VALUES (191, 'The 12 Cellists of The Berlin Philharmonic');
INSERT INTO Artist (ArtistId, Name) VALUES (192, 'Various Artists');
INSERT INTO Artist (ArtistId, Name) VALUES (193, 'Sir Georg Solti & Wiener Philharmoniker');
INSERT INTO Artist (ArtistId, Name) VALUES (194, 'Chic');
INSERT INTO Artist (ArtistId, Name) VALUES (195, 'Marvin Gaye');
INSERT INTO Artist (ArtistId, Name) VALUES (196, 'Talking Heads');
INSERT INTO Artist (ArtistId, Name) VALUES (197, 'Janis Joplin');
INSERT INTO Artist (ArtistId, Name) VALUES (198, 'Jefferson Airplane');
INSERT INTO Artist (ArtistId, Name) VALUES (199, 'Sex Pistols');
INSERT INTO Artist (ArtistId, Name) VALUES (200, 'Gilberto Gil');
INSERT INTO Artist (ArtistId, Name) VALUES (201, 'Battlestar Galactica (Classic)');
INSERT INTO Artist (ArtistId, Name) VALUES (202, 'Aquaman');
INSERT INTO Artist (ArtistId, Name) VALUES (203, 'Baby Consuelo');
INSERT INTO Artist (ArtistId, Name) VALUES (204, 'Avril Lavigne');
INSERT INTO Artist (ArtistId, Name) VALUES (205, 'Big & Rich');
INSERT INTO Artist (ArtistId, Name) VALUES (206, 'Jake Owen');
INSERT INTO Artist (ArtistId, Name) VALUES (207, 'Stevie Wonder');
INSERT INTO Artist (ArtistId, Name) VALUES (208, 'The Office');
INSERT INTO Artist (ArtistId, Name) VALUES (209, 'The Wire');
INSERT INTO Artist (ArtistId, Name) VALUES (210, 'Deadsy');
INSERT INTO Artist (ArtistId, Name) VALUES (211, 'Devo');
INSERT INTO Artist (ArtistId, Name) VALUES (212, 'Nick Cave & The Bad Seeds');
INSERT INTO Artist (ArtistId, Name) VALUES (213, 'Radiohead');
INSERT INTO Artist (ArtistId, Name) VALUES (214, 'Cake');
INSERT INTO Artist (ArtistId, Name) VALUES (215, 'A Cor Do Som');
INSERT INTO Artist (ArtistId, Name) VALUES (216, 'Alanis Morissette');
INSERT INTO Artist (ArtistId, Name) VALUES (217, 'TV Shows');
INSERT INTO Artist (ArtistId, Name) VALUES (218, 'Soundscape');
INSERT INTO Artist (ArtistId, Name) VALUES (219, 'Lost');
INSERT INTO Artist (ArtistId, Name) VALUES (220, 'Battlestar Galactica');
INSERT INTO Artist (ArtistId, Name) VALUES (221, 'Battlestar Galactica (Classic)');
INSERT INTO Artist (ArtistId, Name) VALUES (222, 'Heroes');
INSERT INTO Artist (ArtistId, Name) VALUES (223, 'The Office');
INSERT INTO Artist (ArtistId, Name) VALUES (224, 'Racionais MCs');
INSERT INTO Artist (ArtistId, Name) VALUES (225, 'Planet Hemp');
INSERT INTO Artist (ArtistId, Name) VALUES (226, 'Jorge Ben');
INSERT INTO Artist (ArtistId, Name) VALUES (227, 'Xis');
INSERT INTO Artist (ArtistId, Name) VALUES (228, 'Chico Science & Nação Zumbi');
INSERT INTO Artist (ArtistId, Name) VALUES (229, 'Funkadelic');
INSERT INTO Artist (ArtistId, Name) VALUES (230, 'Banda Black Rio');
INSERT INTO Artist (ArtistId, Name) VALUES (231, 'Rodox');
INSERT INTO Artist (ArtistId, Name) VALUES (232, 'Charlie Brown Jr.');
INSERT INTO Artist (ArtistId, Name) VALUES (233, 'Pedro Luís & A Parede');
INSERT INTO Artist (ArtistId, Name) VALUES (234, 'Los Hermanos');
INSERT INTO Artist (ArtistId, Name) VALUES (235, 'Mundo Livre S/A');
INSERT INTO Artist (ArtistId, Name) VALUES (236, 'Otto');
INSERT INTO Artist (ArtistId, Name) VALUES (237, 'Instituto');
INSERT INTO Artist (ArtistId, Name) VALUES (238, 'Nação Zumbi');
INSERT INTO Artist (ArtistId, Name) VALUES (239, 'DJ Dolores & Orchestra Santa Massa');
INSERT INTO Artist (ArtistId, Name) VALUES (240, 'Seu Jorge');
INSERT INTO Artist (ArtistId, Name) VALUES (241, 'Sabotage E Instituto');
INSERT INTO Artist (ArtistId, Name) VALUES (242, 'Stereo Maracana');
INSERT INTO Artist (ArtistId, Name) VALUES (243, 'Marcos Valle');
INSERT INTO Artist (ArtistId, Name) VALUES (244, 'Milton Nascimento & Bebeto');
INSERT INTO Artist (ArtistId, Name) VALUES (245, 'Antônio Carlos Jobim');
INSERT INTO Artist (ArtistId, Name) VALUES (246, 'João Gilberto');
INSERT INTO Artist (ArtistId, Name) VALUES (247, 'Bebel Gilberto');
INSERT INTO Artist (ArtistId, Name) VALUES (248, 'João Bosco');
INSERT INTO Artist (ArtistId, Name) VALUES (249, 'Toquinho & Vinícius');
INSERT INTO Artist (ArtistId, Name) VALUES (250, 'Vinícius De Moraes & Baden Powell');
INSERT INTO Artist (ArtistId, Name) VALUES (251, 'Cássia Eller');
INSERT INTO Artist (ArtistId, Name) VALUES (252, 'Legião Urbana');
INSERT INTO Artist (ArtistId, Name) VALUES (253, 'Lulu Santos');
INSERT INTO Artist (ArtistId, Name) VALUES (254, 'Marisa Monte');
INSERT INTO Artist (ArtistId, Name) VALUES (255, 'Skank');
INSERT INTO Artist (ArtistId, Name) VALUES (256, 'Zé Ramalho');
INSERT INTO Artist (ArtistId, Name) VALUES (257, 'Chico Buarque');
INSERT INTO Artist (ArtistId, Name) VALUES (258, 'Caetano Veloso');
INSERT INTO Artist (ArtistId, Name) VALUES (259, 'Gilberto Gil');
INSERT INTO Artist (ArtistId, Name) VALUES (260, 'Simply Red');
INSERT INTO Artist (ArtistId, Name) VALUES (261, 'Contract');
INSERT INTO Artist (ArtistId, Name) VALUES (262, 'Kid Abelha');
INSERT INTO Artist (ArtistId, Name) VALUES (263, 'Djavan');
INSERT INTO Artist (ArtistId, Name) VALUES (264, 'Elza Soares');
INSERT INTO Artist (ArtistId, Name) VALUES (265, 'Barão Vermelho');
INSERT INTO Artist (ArtistId, Name) VALUES (266, 'Titãs');
INSERT INTO Artist (ArtistId, Name) VALUES (267, 'Hermeto Pascoal');
INSERT INTO Artist (ArtistId, Name) VALUES (268, 'Azymuth');
INSERT INTO Artist (ArtistId, Name) VALUES (269, 'Milton Nascimento');
INSERT INTO Artist (ArtistId, Name) VALUES (270, 'Egberto Gismonti');
INSERT INTO Artist (ArtistId, Name) VALUES (271, 'Nando Reis');
INSERT INTO Artist (ArtistId, Name) VALUES (272, 'Pedro Luís E A Parede');
INSERT INTO Artist (ArtistId, Name) VALUES (273, 'O Rappa');
INSERT INTO Artist (ArtistId, Name) VALUES (274, 'Ed Motta');
INSERT INTO Artist (ArtistId, Name) VALUES (275, 'Fernanda Porto');
GO

-- Albums (subset — 50 albums covering the Artist IDs used in Tracks below)
INSERT INTO Album (AlbumId, Title, ArtistId) VALUES (1, 'For Those About To Rock We Salute You', 1);
INSERT INTO Album (AlbumId, Title, ArtistId) VALUES (2, 'Balls to the Wall', 2);
INSERT INTO Album (AlbumId, Title, ArtistId) VALUES (3, 'Restless and Wild', 2);
INSERT INTO Album (AlbumId, Title, ArtistId) VALUES (4, 'Let There Be Rock', 1);
INSERT INTO Album (AlbumId, Title, ArtistId) VALUES (5, 'Big Ones', 3);
INSERT INTO Album (AlbumId, Title, ArtistId) VALUES (6, 'Jagged Little Pill', 4);
INSERT INTO Album (AlbumId, Title, ArtistId) VALUES (7, 'Facelift', 5);
INSERT INTO Album (AlbumId, Title, ArtistId) VALUES (8, 'Warner 25 Anos', 6);
INSERT INTO Album (AlbumId, Title, ArtistId) VALUES (9, 'Plays Metallica By Four Cellos', 7);
INSERT INTO Album (AlbumId, Title, ArtistId) VALUES (10, 'Audioslave', 8);
INSERT INTO Album (AlbumId, Title, ArtistId) VALUES (11, 'Out Of Exile', 8);
INSERT INTO Album (AlbumId, Title, ArtistId) VALUES (12, 'BackBeat Soundtrack', 9);
INSERT INTO Album (AlbumId, Title, ArtistId) VALUES (13, 'The Best Of Billy Cobham', 10);
INSERT INTO Album (AlbumId, Title, ArtistId) VALUES (14, 'Alcohol Fueled Brewtality Live! [Disc 1]', 11);
INSERT INTO Album (AlbumId, Title, ArtistId) VALUES (15, 'Alcohol Fueled Brewtality Live! [Disc 2]', 11);
INSERT INTO Album (AlbumId, Title, ArtistId) VALUES (16, 'Black Sabbath', 12);
INSERT INTO Album (AlbumId, Title, ArtistId) VALUES (17, 'Black Sabbath Vol. 4 (Remaster)', 12);
INSERT INTO Album (AlbumId, Title, ArtistId) VALUES (18, 'Body Count', 13);
INSERT INTO Album (AlbumId, Title, ArtistId) VALUES (19, 'Chemical Wedding', 14);
INSERT INTO Album (AlbumId, Title, ArtistId) VALUES (20, 'The Best Of Buddy Guy - The Millenium Collection', 15);
INSERT INTO Album (AlbumId, Title, ArtistId) VALUES (21, 'Prenda Minha', 16);
INSERT INTO Album (AlbumId, Title, ArtistId) VALUES (22, 'Sozinho Remix Ao Vivo', 16);
INSERT INTO Album (AlbumId, Title, ArtistId) VALUES (23, 'Minha Historia', 17);
INSERT INTO Album (AlbumId, Title, ArtistId) VALUES (24, 'Afrociberdelia', 18);
INSERT INTO Album (AlbumId, Title, ArtistId) VALUES (25, 'Da Lama Ao Caos', 18);
INSERT INTO Album (AlbumId, Title, ArtistId) VALUES (26, 'Acústico MTV [Live]', 19);
INSERT INTO Album (AlbumId, Title, ArtistId) VALUES (27, 'Cidade Negra - Hits', 19);
INSERT INTO Album (AlbumId, Title, ArtistId) VALUES (28, 'Na Pista', 20);
INSERT INTO Album (AlbumId, Title, ArtistId) VALUES (29, 'Axé Bahia 2001', 21);
INSERT INTO Album (AlbumId, Title, ArtistId) VALUES (30, 'BBC Sessions [Disc 1] [Live]', 22);
INSERT INTO Album (AlbumId, Title, ArtistId) VALUES (31, 'Bongo Fury', 23);
INSERT INTO Album (AlbumId, Title, ArtistId) VALUES (32, 'Carnaval 2001', 21);
INSERT INTO Album (AlbumId, Title, ArtistId) VALUES (33, 'Chill: Brazil (Disc 1)', 24);
INSERT INTO Album (AlbumId, Title, ArtistId) VALUES (34, 'Chill: Brazil (Disc 2)', 25);
INSERT INTO Album (AlbumId, Title, ArtistId) VALUES (35, 'Garage Inc. (Disc 1)', 50);
INSERT INTO Album (AlbumId, Title, ArtistId) VALUES (36, 'Greatest Hits II', 51);
INSERT INTO Album (AlbumId, Title, ArtistId) VALUES (37, 'Greatest Kiss', 52);
INSERT INTO Album (AlbumId, Title, ArtistId) VALUES (38, 'Heart of the Night', 53);
INSERT INTO Album (AlbumId, Title, ArtistId) VALUES (39, 'International Superhits', 54);
INSERT INTO Album (AlbumId, Title, ArtistId) VALUES (40, 'Let''s Talk About Love', 55);
INSERT INTO Album (AlbumId, Title, ArtistId) VALUES (41, 'Live [Disc 1]', 56);
INSERT INTO Album (AlbumId, Title, ArtistId) VALUES (42, 'Machine Head', 57);
INSERT INTO Album (AlbumId, Title, ArtistId) VALUES (43, 'Supernatural', 58);
INSERT INTO Album (AlbumId, Title, ArtistId) VALUES (44, 'Santana - As Years Go By', 58);
INSERT INTO Album (AlbumId, Title, ArtistId) VALUES (45, 'Santana Live', 58);
INSERT INTO Album (AlbumId, Title, ArtistId) VALUES (46, 'Sketches of Spain', 67);
INSERT INTO Album (AlbumId, Title, ArtistId) VALUES (47, 'The Essential Miles Davis [Disc 1]', 67);
INSERT INTO Album (AlbumId, Title, ArtistId) VALUES (48, 'The Essential Miles Davis [Disc 2]', 67);
INSERT INTO Album (AlbumId, Title, ArtistId) VALUES (49, 'Blue Moods', 67);
INSERT INTO Album (AlbumId, Title, ArtistId) VALUES (50, 'Up An'' Atom', 68);
GO

-- Employees
INSERT INTO Employee (EmployeeId, LastName, FirstName, Title, ReportsTo, BirthDate, HireDate, Address, City, State, Country, PostalCode, Phone, Fax, Email)
VALUES (1, 'Adams', 'Andrew', 'General Manager', NULL, '1962-02-18', '2002-08-14', '11120 Jasper Ave NW', 'Edmonton', 'AB', 'Canada', 'T5K 2N1', '+1 (780) 428-9482', '+1 (780) 428-3457', 'andrew@chinookcorp.com');
INSERT INTO Employee (EmployeeId, LastName, FirstName, Title, ReportsTo, BirthDate, HireDate, Address, City, State, Country, PostalCode, Phone, Fax, Email)
VALUES (2, 'Edwards', 'Nancy', 'Sales Manager', 1, '1958-12-08', '2002-05-01', '825 8 Ave SW', 'Calgary', 'AB', 'Canada', 'T2P 2T3', '+1 (403) 262-3443', '+1 (403) 262-3322', 'nancy@chinookcorp.com');
INSERT INTO Employee (EmployeeId, LastName, FirstName, Title, ReportsTo, BirthDate, HireDate, Address, City, State, Country, PostalCode, Phone, Fax, Email)
VALUES (3, 'Peacock', 'Jane', 'Sales Support Agent', 2, '1973-08-29', '2002-04-01', '1111 6 Ave SW', 'Calgary', 'AB', 'Canada', 'T2P 5M5', '+1 (403) 262-3443', '+1 (403) 262-6712', 'jane@chinookcorp.com');
INSERT INTO Employee (EmployeeId, LastName, FirstName, Title, ReportsTo, BirthDate, HireDate, Address, City, State, Country, PostalCode, Phone, Fax, Email)
VALUES (4, 'Park', 'Margaret', 'Sales Support Agent', 2, '1947-09-19', '2003-05-03', '683 10 Street SW', 'Calgary', 'AB', 'Canada', 'T2P 5G3', '+1 (403) 263-4423', '+1 (403) 263-4289', 'margaret@chinookcorp.com');
INSERT INTO Employee (EmployeeId, LastName, FirstName, Title, ReportsTo, BirthDate, HireDate, Address, City, State, Country, PostalCode, Phone, Fax, Email)
VALUES (5, 'Johnson', 'Steve', 'Sales Support Agent', 2, '1965-03-03', '2003-10-17', '7727B 41 Ave', 'Calgary', 'AB', 'Canada', 'T3B 1Y7', '1 (780) 836-9987', '1 (780) 836-9543', 'steve@chinookcorp.com');
INSERT INTO Employee (EmployeeId, LastName, FirstName, Title, ReportsTo, BirthDate, HireDate, Address, City, State, Country, PostalCode, Phone, Fax, Email)
VALUES (6, 'Mitchell', 'Michael', 'IT Manager', 1, '1973-07-01', '2003-10-17', '5827 Bowness Road NW', 'Calgary', 'AB', 'Canada', 'T3B 0C5', '+1 (403) 246-9887', '+1 (403) 246-9899', 'michael@chinookcorp.com');
INSERT INTO Employee (EmployeeId, LastName, FirstName, Title, ReportsTo, BirthDate, HireDate, Address, City, State, Country, PostalCode, Phone, Fax, Email)
VALUES (7, 'King', 'Robert', 'IT Staff', 6, '1970-05-29', '2004-01-02', '590 Columbia Boulevard West', 'Lethbridge', 'AB', 'Canada', 'T1K 5N8', '+1 (403) 456-9986', '+1 (403) 456-8485', 'robert@chinookcorp.com');
INSERT INTO Employee (EmployeeId, LastName, FirstName, Title, ReportsTo, BirthDate, HireDate, Address, City, State, Country, PostalCode, Phone, Fax, Email)
VALUES (8, 'Callahan', 'Laura', 'IT Staff', 6, '1968-01-09', '2004-03-04', '923 7 ST NW', 'Lethbridge', 'AB', 'Canada', 'T1H 1Y8', '+1 (403) 467-3351', '+1 (403) 467-8772', 'laura@chinookcorp.com');
GO

-- Customers (10 representative rows)
INSERT INTO Customer (CustomerId, FirstName, LastName, Company, Address, City, State, Country, PostalCode, Phone, Fax, Email, SupportRepId)
VALUES (1, 'Luís', 'Gonçalves', 'Embraer - Empresa Brasileira de Aeronáutica S.A.', 'Av. Brigadeiro Faria Lima, 2170', 'São José dos Campos', 'SP', 'Brazil', '12227-000', '+55 (12) 3923-5555', '+55 (12) 3923-5566', 'luisg@embraer.com.br', 3);
INSERT INTO Customer (CustomerId, FirstName, LastName, Company, Address, City, State, Country, PostalCode, Phone, Fax, Email, SupportRepId)
VALUES (2, 'Leonie', 'Köhler', NULL, 'Theodor-Heuss-Straße 34', 'Stuttgart', NULL, 'Germany', '70174', '+49 0711 2842222', NULL, 'leonekohler@surfeu.de', 5);
INSERT INTO Customer (CustomerId, FirstName, LastName, Company, Address, City, State, Country, PostalCode, Phone, Fax, Email, SupportRepId)
VALUES (3, 'François', 'Tremblay', NULL, '1498 rue Bélanger', 'Montréal', 'QC', 'Canada', 'H2G 1A7', '+1 (514) 721-4711', NULL, 'ftremblay@gmail.com', 3);
INSERT INTO Customer (CustomerId, FirstName, LastName, Company, Address, City, State, Country, PostalCode, Phone, Fax, Email, SupportRepId)
VALUES (4, 'Bjørn', 'Hansen', NULL, 'Ullevålsveien 14', 'Oslo', NULL, 'Norway', '0171', '+47 22 44 22 22', NULL, 'bjorn.hansen@yahoo.no', 4);
INSERT INTO Customer (CustomerId, FirstName, LastName, Company, Address, City, State, Country, PostalCode, Phone, Fax, Email, SupportRepId)
VALUES (5, 'František', 'Wichterlová', 'JetBrains s.r.o.', 'Klanova 9/506', 'Prague', NULL, 'Czech Republic', '14700', '+420 2 4172 5555', '+420 2 4172 5555', 'frantisekw@jetbrains.com', 4);
INSERT INTO Customer (CustomerId, FirstName, LastName, Company, Address, City, State, Country, PostalCode, Phone, Fax, Email, SupportRepId)
VALUES (6, 'Helena', 'Holý', NULL, 'Rilská 3174/6', 'Prague', NULL, 'Czech Republic', '14300', '+420 2 4177 0449', NULL, 'hholy@gmail.com', 5);
INSERT INTO Customer (CustomerId, FirstName, LastName, Company, Address, City, State, Country, PostalCode, Phone, Fax, Email, SupportRepId)
VALUES (7, 'Astrid', 'Gruber', NULL, 'Rotenturmstraße 4, 1010 Innere Stadt', 'Vienne', NULL, 'Austria', '1010', '+43 01 5134505', NULL, 'astrid.gruber@apple.at', 5);
INSERT INTO Customer (CustomerId, FirstName, LastName, Company, Address, City, State, Country, PostalCode, Phone, Fax, Email, SupportRepId)
VALUES (8, 'Daan', 'Peeters', NULL, 'Grétrystraat 63', 'Brussels', NULL, 'Belgium', '1000', '+32 02 219 03 03', NULL, 'daan_peeters@apple.be', 4);
INSERT INTO Customer (CustomerId, FirstName, LastName, Company, Address, City, State, Country, PostalCode, Phone, Fax, Email, SupportRepId)
VALUES (9, 'Kara', 'Nielsen', NULL, 'Sønder Boulevard 51', 'Copenhagen', NULL, 'Denmark', '1720', '+453 3331 9991', NULL, 'kara.nielsen@jubii.dk', 4);
INSERT INTO Customer (CustomerId, FirstName, LastName, Company, Address, City, State, Country, PostalCode, Phone, Fax, Email, SupportRepId)
VALUES (10, 'Eduardo', 'Martins', 'Woodstock Discos', 'Rua Dr. Falcão Filho, 155', 'São Paulo', 'SP', 'Brazil', '01007-010', '+55 (11) 3033-5446', '+55 (11) 3033-4564', 'eduardo@woodstock.com.br', 4);
GO

-- Playlists
INSERT INTO Playlist (PlaylistId, Name) VALUES (1, 'Music');
INSERT INTO Playlist (PlaylistId, Name) VALUES (2, 'Movies');
INSERT INTO Playlist (PlaylistId, Name) VALUES (3, 'TV Shows');
INSERT INTO Playlist (PlaylistId, Name) VALUES (4, 'Audiobooks');
INSERT INTO Playlist (PlaylistId, Name) VALUES (5, '90s Music');
INSERT INTO Playlist (PlaylistId, Name) VALUES (6, 'Audiobooks');
INSERT INTO Playlist (PlaylistId, Name) VALUES (7, 'Movies');
INSERT INTO Playlist (PlaylistId, Name) VALUES (8, 'Music');
INSERT INTO Playlist (PlaylistId, Name) VALUES (9, 'Music Videos');
INSERT INTO Playlist (PlaylistId, Name) VALUES (10, 'TV Shows');
INSERT INTO Playlist (PlaylistId, Name) VALUES (11, 'Brazilian Music');
INSERT INTO Playlist (PlaylistId, Name) VALUES (12, 'Classical');
INSERT INTO Playlist (PlaylistId, Name) VALUES (13, 'Classical 101 - Deep Cuts');
INSERT INTO Playlist (PlaylistId, Name) VALUES (14, 'Classical 101 - Next Steps');
INSERT INTO Playlist (PlaylistId, Name) VALUES (15, 'Classical 101 - The Basics');
INSERT INTO Playlist (PlaylistId, Name) VALUES (16, 'Grunge');
INSERT INTO Playlist (PlaylistId, Name) VALUES (17, 'Heavy Metal Classic');
INSERT INTO Playlist (PlaylistId, Name) VALUES (18, 'On-The-Go 1');
GO

-- Tracks (50 representative rows)
INSERT INTO Track (TrackId, Name, AlbumId, MediaTypeId, GenreId, Composer, Milliseconds, Bytes, UnitPrice)
VALUES (1, 'For Those About To Rock (We Salute You)', 1, 1, 1, 'Angus Young, Malcolm Young, Brian Johnson', 343719, 11170334, 0.99);
INSERT INTO Track (TrackId, Name, AlbumId, MediaTypeId, GenreId, Composer, Milliseconds, Bytes, UnitPrice)
VALUES (2, 'Balls to the Wall', 2, 2, 1, NULL, 342562, 5510424, 0.99);
INSERT INTO Track (TrackId, Name, AlbumId, MediaTypeId, GenreId, Composer, Milliseconds, Bytes, UnitPrice)
VALUES (3, 'Fast As a Shark', 3, 2, 1, 'F. Baltes, S. Kaufman, U. Dirkscneider & W. Hoffman', 230619, 3990994, 0.99);
INSERT INTO Track (TrackId, Name, AlbumId, MediaTypeId, GenreId, Composer, Milliseconds, Bytes, UnitPrice)
VALUES (4, 'Restless and Wild', 3, 2, 1, 'F. Baltes, R.A. Smith-Diesel, S. Kaufman, U. Dirkscneider & W. Hoffman', 252051, 4331779, 0.99);
INSERT INTO Track (TrackId, Name, AlbumId, MediaTypeId, GenreId, Composer, Milliseconds, Bytes, UnitPrice)
VALUES (5, 'Princess of the Dawn', 3, 2, 1, 'Deaffy & R.A. Smith-Diesel', 375418, 6290521, 0.99);
INSERT INTO Track (TrackId, Name, AlbumId, MediaTypeId, GenreId, Composer, Milliseconds, Bytes, UnitPrice)
VALUES (6, 'Put The Finger On You', 1, 1, 1, 'Angus Young, Malcolm Young, Brian Johnson', 205662, 6713451, 0.99);
INSERT INTO Track (TrackId, Name, AlbumId, MediaTypeId, GenreId, Composer, Milliseconds, Bytes, UnitPrice)
VALUES (7, 'Let''s Get It Up', 1, 1, 1, 'Angus Young, Malcolm Young, Brian Johnson', 233926, 7636561, 0.99);
INSERT INTO Track (TrackId, Name, AlbumId, MediaTypeId, GenreId, Composer, Milliseconds, Bytes, UnitPrice)
VALUES (8, 'Inject The Venom', 1, 1, 1, 'Angus Young, Malcolm Young, Brian Johnson', 210834, 6852860, 0.99);
INSERT INTO Track (TrackId, Name, AlbumId, MediaTypeId, GenreId, Composer, Milliseconds, Bytes, UnitPrice)
VALUES (9, 'Snowballed', 1, 1, 1, 'Angus Young, Malcolm Young, Brian Johnson', 203102, 6599424, 0.99);
INSERT INTO Track (TrackId, Name, AlbumId, MediaTypeId, GenreId, Composer, Milliseconds, Bytes, UnitPrice)
VALUES (10, 'Evil Walks', 1, 1, 1, 'Angus Young, Malcolm Young, Brian Johnson', 263497, 8611245, 0.99);
INSERT INTO Track (TrackId, Name, AlbumId, MediaTypeId, GenreId, Composer, Milliseconds, Bytes, UnitPrice)
VALUES (11, 'C.O.D.', 1, 1, 1, 'Angus Young, Malcolm Young, Brian Johnson', 199836, 6566314, 0.99);
INSERT INTO Track (TrackId, Name, AlbumId, MediaTypeId, GenreId, Composer, Milliseconds, Bytes, UnitPrice)
VALUES (12, 'Breaking The Rules', 1, 1, 1, 'Angus Young, Malcolm Young, Brian Johnson', 263288, 8596840, 0.99);
INSERT INTO Track (TrackId, Name, AlbumId, MediaTypeId, GenreId, Composer, Milliseconds, Bytes, UnitPrice)
VALUES (13, 'Night Of The Long Knives', 1, 1, 1, 'Angus Young, Malcolm Young, Brian Johnson', 205688, 6706347, 0.99);
INSERT INTO Track (TrackId, Name, AlbumId, MediaTypeId, GenreId, Composer, Milliseconds, Bytes, UnitPrice)
VALUES (14, 'Spellbound', 1, 1, 1, 'Angus Young, Malcolm Young, Brian Johnson', 270863, 8817038, 0.99);
INSERT INTO Track (TrackId, Name, AlbumId, MediaTypeId, GenreId, Composer, Milliseconds, Bytes, UnitPrice)
VALUES (15, 'Go Down', 4, 1, 1, 'AC/DC', 331180, 10847611, 0.99);
INSERT INTO Track (TrackId, Name, AlbumId, MediaTypeId, GenreId, Composer, Milliseconds, Bytes, UnitPrice)
VALUES (16, 'Dog Eat Dog', 4, 1, 1, 'AC/DC', 215196, 7032162, 0.99);
INSERT INTO Track (TrackId, Name, AlbumId, MediaTypeId, GenreId, Composer, Milliseconds, Bytes, UnitPrice)
VALUES (17, 'Let There Be Rock', 4, 1, 1, 'AC/DC', 366654, 12021261, 0.99);
INSERT INTO Track (TrackId, Name, AlbumId, MediaTypeId, GenreId, Composer, Milliseconds, Bytes, UnitPrice)
VALUES (18, 'Bad Boy Boogie', 4, 1, 1, 'AC/DC', 267728, 8776140, 0.99);
INSERT INTO Track (TrackId, Name, AlbumId, MediaTypeId, GenreId, Composer, Milliseconds, Bytes, UnitPrice)
VALUES (19, 'Problem Child', 4, 1, 1, 'AC/DC', 325041, 10617116, 0.99);
INSERT INTO Track (TrackId, Name, AlbumId, MediaTypeId, GenreId, Composer, Milliseconds, Bytes, UnitPrice)
VALUES (20, 'Overdose', 4, 1, 1, 'AC/DC', 369319, 12066294, 0.99);
INSERT INTO Track (TrackId, Name, AlbumId, MediaTypeId, GenreId, Composer, Milliseconds, Bytes, UnitPrice)
VALUES (21, 'Hell Ain''t A Bad Place To Be', 4, 1, 1, 'AC/DC', 254380, 8331286, 0.99);
INSERT INTO Track (TrackId, Name, AlbumId, MediaTypeId, GenreId, Composer, Milliseconds, Bytes, UnitPrice)
VALUES (22, 'Whole Lotta Rosie', 4, 1, 1, 'AC/DC', 323761, 10547154, 0.99);
INSERT INTO Track (TrackId, Name, AlbumId, MediaTypeId, GenreId, Composer, Milliseconds, Bytes, UnitPrice)
VALUES (23, 'Walk On Water', 5, 1, 1, 'Steven Tyler, Joe Perry, Jack Blades, Tommy Shaw', 295680, 9719579, 0.99);
INSERT INTO Track (TrackId, Name, AlbumId, MediaTypeId, GenreId, Composer, Milliseconds, Bytes, UnitPrice)
VALUES (24, 'Love In An Elevator', 5, 1, 1, 'Steven Tyler, Joe Perry', 321828, 10552051, 0.99);
INSERT INTO Track (TrackId, Name, AlbumId, MediaTypeId, GenreId, Composer, Milliseconds, Bytes, UnitPrice)
VALUES (25, 'Rag Doll', 5, 1, 1, 'Steven Tyler, Joe Perry, Jim Vallance, Holly Knight', 264698, 8675345, 0.99);
INSERT INTO Track (TrackId, Name, AlbumId, MediaTypeId, GenreId, Composer, Milliseconds, Bytes, UnitPrice)
VALUES (26, 'What It Takes', 5, 1, 1, 'Steven Tyler, Joe Perry, Desmond Child', 310622, 10144730, 0.99);
INSERT INTO Track (TrackId, Name, AlbumId, MediaTypeId, GenreId, Composer, Milliseconds, Bytes, UnitPrice)
VALUES (27, 'Dude (Looks Like A Lady)', 5, 1, 1, 'Steven Tyler, Joe Perry, Desmond Child', 264855, 8679940, 0.99);
INSERT INTO Track (TrackId, Name, AlbumId, MediaTypeId, GenreId, Composer, Milliseconds, Bytes, UnitPrice)
VALUES (28, 'Janie''s Got A Gun', 5, 1, 1, 'Steven Tyler, Tom Hamilton', 330736, 10869391, 0.99);
INSERT INTO Track (TrackId, Name, AlbumId, MediaTypeId, GenreId, Composer, Milliseconds, Bytes, UnitPrice)
VALUES (29, 'Cryin''', 5, 1, 1, 'Steven Tyler, Joe Perry, Taylor Rhodes', 309263, 10056995, 0.99);
INSERT INTO Track (TrackId, Name, AlbumId, MediaTypeId, GenreId, Composer, Milliseconds, Bytes, UnitPrice)
VALUES (30, 'Amazing', 5, 1, 1, 'Steven Tyler, Richie Supa', 356519, 11616195, 0.99);
INSERT INTO Track (TrackId, Name, AlbumId, MediaTypeId, GenreId, Composer, Milliseconds, Bytes, UnitPrice)
VALUES (31, 'Blind Man', 5, 1, 1, 'Steven Tyler, Joe Perry, Taylor Rhodes', 240718, 7877453, 0.99);
INSERT INTO Track (TrackId, Name, AlbumId, MediaTypeId, GenreId, Composer, Milliseconds, Bytes, UnitPrice)
VALUES (32, 'Deuces Are Wild', 5, 1, 1, 'Steven Tyler, Jim Vallance', 215875, 7074167, 0.99);
INSERT INTO Track (TrackId, Name, AlbumId, MediaTypeId, GenreId, Composer, Milliseconds, Bytes, UnitPrice)
VALUES (33, 'The Other Side', 5, 1, 1, 'Steven Tyler, Jim Vallance', 244375, 7983270, 0.99);
INSERT INTO Track (TrackId, Name, AlbumId, MediaTypeId, GenreId, Composer, Milliseconds, Bytes, UnitPrice)
VALUES (34, 'Crazy', 5, 1, 1, 'Steven Tyler, Joe Perry, Desmond Child', 316656, 10402398, 0.99);
INSERT INTO Track (TrackId, Name, AlbumId, MediaTypeId, GenreId, Composer, Milliseconds, Bytes, UnitPrice)
VALUES (35, 'Eat The Rich', 5, 1, 1, 'Steven Tyler, Joe Perry, Jim Vallance', 251036, 8262039, 0.99);
INSERT INTO Track (TrackId, Name, AlbumId, MediaTypeId, GenreId, Composer, Milliseconds, Bytes, UnitPrice)
VALUES (36, 'Angel', 5, 1, 1, 'Steven Tyler, Desmond Child', 307617, 9989331, 0.99);
INSERT INTO Track (TrackId, Name, AlbumId, MediaTypeId, GenreId, Composer, Milliseconds, Bytes, UnitPrice)
VALUES (37, 'Livin'' On The Edge', 5, 1, 1, 'Steven Tyler, Joe Perry, Mark Hudson', 381231, 12374569, 0.99);
INSERT INTO Track (TrackId, Name, AlbumId, MediaTypeId, GenreId, Composer, Milliseconds, Bytes, UnitPrice)
VALUES (38, 'All I Really Want', 6, 1, 1, 'Alanis Morissette & Glenn Ballard', 284891, 9375567, 0.99);
INSERT INTO Track (TrackId, Name, AlbumId, MediaTypeId, GenreId, Composer, Milliseconds, Bytes, UnitPrice)
VALUES (39, 'You Oughta Know', 6, 1, 1, 'Alanis Morissette & Glenn Ballard', 249234, 8196916, 0.99);
INSERT INTO Track (TrackId, Name, AlbumId, MediaTypeId, GenreId, Composer, Milliseconds, Bytes, UnitPrice)
VALUES (40, 'Perfect', 6, 1, 1, 'Alanis Morissette & Glenn Ballard', 188133, 6145404, 0.99);
INSERT INTO Track (TrackId, Name, AlbumId, MediaTypeId, GenreId, Composer, Milliseconds, Bytes, UnitPrice)
VALUES (41, 'Hand In My Pocket', 6, 1, 1, 'Alanis Morissette & Glenn Ballard', 221570, 7224246, 0.99);
INSERT INTO Track (TrackId, Name, AlbumId, MediaTypeId, GenreId, Composer, Milliseconds, Bytes, UnitPrice)
VALUES (42, 'Right Through You', 6, 1, 1, 'Alanis Morissette & Glenn Ballard', 176117, 5793082, 0.99);
INSERT INTO Track (TrackId, Name, AlbumId, MediaTypeId, GenreId, Composer, Milliseconds, Bytes, UnitPrice)
VALUES (43, 'Forgiven', 6, 1, 1, 'Alanis Morissette & Glenn Ballard', 300355, 9753256, 0.99);
INSERT INTO Track (TrackId, Name, AlbumId, MediaTypeId, GenreId, Composer, Milliseconds, Bytes, UnitPrice)
VALUES (44, 'You Learn', 6, 1, 1, 'Alanis Morissette & Glenn Ballard', 239699, 7824130, 0.99);
INSERT INTO Track (TrackId, Name, AlbumId, MediaTypeId, GenreId, Composer, Milliseconds, Bytes, UnitPrice)
VALUES (45, 'Head Over Feet', 6, 1, 1, 'Alanis Morissette & Glenn Ballard', 267493, 8758008, 0.99);
INSERT INTO Track (TrackId, Name, AlbumId, MediaTypeId, GenreId, Composer, Milliseconds, Bytes, UnitPrice)
VALUES (46, 'Mary Jane', 6, 1, 1, 'Alanis Morissette & Glenn Ballard', 294511, 9690069, 0.99);
INSERT INTO Track (TrackId, Name, AlbumId, MediaTypeId, GenreId, Composer, Milliseconds, Bytes, UnitPrice)
VALUES (47, 'Ironic', 6, 1, 1, 'Alanis Morissette & Glenn Ballard', 229825, 7598866, 0.99);
INSERT INTO Track (TrackId, Name, AlbumId, MediaTypeId, GenreId, Composer, Milliseconds, Bytes, UnitPrice)
VALUES (48, 'Not The Doctor', 6, 1, 1, 'Alanis Morissette & Glenn Ballard', 227631, 7478472, 0.99);
INSERT INTO Track (TrackId, Name, AlbumId, MediaTypeId, GenreId, Composer, Milliseconds, Bytes, UnitPrice)
VALUES (49, 'Wake Up', 6, 1, 1, 'Alanis Morissette & Glenn Ballard', 293485, 9659039, 0.99);
INSERT INTO Track (TrackId, Name, AlbumId, MediaTypeId, GenreId, Composer, Milliseconds, Bytes, UnitPrice)
VALUES (50, 'You Oughta Know (Alternate)', 6, 1, 1, 'Alanis Morissette & Glenn Ballard', 491885, 16008629, 0.99);
GO

-- Sample Invoices and InvoiceLines
INSERT INTO Invoice (InvoiceId, CustomerId, InvoiceDate, BillingAddress, BillingCity, BillingState, BillingCountry, BillingPostalCode, Total)
VALUES (1, 2, '2009-01-01', 'Theodor-Heuss-Straße 34', 'Stuttgart', NULL, 'Germany', '70174', 1.98);
INSERT INTO Invoice (InvoiceId, CustomerId, InvoiceDate, BillingAddress, BillingCity, BillingState, BillingCountry, BillingPostalCode, Total)
VALUES (2, 4, '2009-01-02', 'Ullevålsveien 14', 'Oslo', NULL, 'Norway', '0171', 3.96);
INSERT INTO Invoice (InvoiceId, CustomerId, InvoiceDate, BillingAddress, BillingCity, BillingState, BillingCountry, BillingPostalCode, Total)
VALUES (3, 8, '2009-01-03', 'Grétrystraat 63', 'Brussels', NULL, 'Belgium', '1000', 5.94);
INSERT INTO Invoice (InvoiceId, CustomerId, InvoiceDate, BillingAddress, BillingCity, BillingState, BillingCountry, BillingPostalCode, Total)
VALUES (4, 14, '2009-01-06', '8210 111 ST NW', 'Edmonton', 'AB', 'Canada', 'T6G 2C7', 8.91);
INSERT INTO Invoice (InvoiceId, CustomerId, InvoiceDate, BillingAddress, BillingCity, BillingState, BillingCountry, BillingPostalCode, Total)
VALUES (5, 23, '2009-01-11', '69 Salem Street', 'Boston', 'MA', 'USA', '2113', 13.86);
GO

INSERT INTO InvoiceLine (InvoiceLineId, InvoiceId, TrackId, UnitPrice, Quantity)
VALUES (1, 1, 2, 0.99, 1);
INSERT INTO InvoiceLine (InvoiceLineId, InvoiceId, TrackId, UnitPrice, Quantity)
VALUES (2, 1, 4, 0.99, 1);
INSERT INTO InvoiceLine (InvoiceLineId, InvoiceId, TrackId, UnitPrice, Quantity)
VALUES (3, 2, 6, 0.99, 1);
INSERT INTO InvoiceLine (InvoiceLineId, InvoiceId, TrackId, UnitPrice, Quantity)
VALUES (4, 2, 8, 0.99, 1);
INSERT INTO InvoiceLine (InvoiceLineId, InvoiceId, TrackId, UnitPrice, Quantity)
VALUES (5, 2, 10, 0.99, 1);
INSERT INTO InvoiceLine (InvoiceLineId, InvoiceId, TrackId, UnitPrice, Quantity)
VALUES (6, 2, 12, 0.99, 1);
INSERT INTO InvoiceLine (InvoiceLineId, InvoiceId, TrackId, UnitPrice, Quantity)
VALUES (7, 3, 16, 0.99, 1);
INSERT INTO InvoiceLine (InvoiceLineId, InvoiceId, TrackId, UnitPrice, Quantity)
VALUES (8, 3, 20, 0.99, 1);
INSERT INTO InvoiceLine (InvoiceLineId, InvoiceId, TrackId, UnitPrice, Quantity)
VALUES (9, 3, 24, 0.99, 1);
INSERT INTO InvoiceLine (InvoiceLineId, InvoiceId, TrackId, UnitPrice, Quantity)
VALUES (10, 3, 28, 0.99, 1);
GO

-- PlaylistTrack (sample)
INSERT INTO PlaylistTrack (PlaylistId, TrackId) VALUES (1, 1);
INSERT INTO PlaylistTrack (PlaylistId, TrackId) VALUES (1, 2);
INSERT INTO PlaylistTrack (PlaylistId, TrackId) VALUES (1, 3);
INSERT INTO PlaylistTrack (PlaylistId, TrackId) VALUES (1, 4);
INSERT INTO PlaylistTrack (PlaylistId, TrackId) VALUES (1, 5);
INSERT INTO PlaylistTrack (PlaylistId, TrackId) VALUES (5, 38);
INSERT INTO PlaylistTrack (PlaylistId, TrackId) VALUES (5, 39);
INSERT INTO PlaylistTrack (PlaylistId, TrackId) VALUES (5, 40);
INSERT INTO PlaylistTrack (PlaylistId, TrackId) VALUES (17, 15);
INSERT INTO PlaylistTrack (PlaylistId, TrackId) VALUES (17, 16);
INSERT INTO PlaylistTrack (PlaylistId, TrackId) VALUES (17, 17);
GO

/*******************************************************************************
   Enable CDC on database and all tables
   (Requires SQL Server Agent to be running)
********************************************************************************/
EXEC sys.sp_cdc_enable_db;
GO

EXEC sys.sp_cdc_enable_table @source_schema = N'dbo', @source_name = N'Artist',       @role_name = NULL;
EXEC sys.sp_cdc_enable_table @source_schema = N'dbo', @source_name = N'Album',        @role_name = NULL;
EXEC sys.sp_cdc_enable_table @source_schema = N'dbo', @source_name = N'Genre',        @role_name = NULL;
EXEC sys.sp_cdc_enable_table @source_schema = N'dbo', @source_name = N'MediaType',    @role_name = NULL;
EXEC sys.sp_cdc_enable_table @source_schema = N'dbo', @source_name = N'Track',        @role_name = NULL;
EXEC sys.sp_cdc_enable_table @source_schema = N'dbo', @source_name = N'Employee',     @role_name = NULL;
EXEC sys.sp_cdc_enable_table @source_schema = N'dbo', @source_name = N'Customer',     @role_name = NULL;
EXEC sys.sp_cdc_enable_table @source_schema = N'dbo', @source_name = N'Invoice',      @role_name = NULL;
EXEC sys.sp_cdc_enable_table @source_schema = N'dbo', @source_name = N'InvoiceLine',  @role_name = NULL;
EXEC sys.sp_cdc_enable_table @source_schema = N'dbo', @source_name = N'Playlist',     @role_name = NULL;
EXEC sys.sp_cdc_enable_table @source_schema = N'dbo', @source_name = N'PlaylistTrack',@role_name = NULL;
GO
