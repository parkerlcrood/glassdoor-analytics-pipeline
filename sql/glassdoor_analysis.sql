DROP TABLE IF EXISTS DS_Jobs;

DROP TABLE IF EXISTS Cleaned_Listings;

SELECT * INTO DS_Jobs FROM GlassdoorCleaning..GlassdoorJobs;

--Remove specifiers for Glassdoor Estimations and Employer Provided in the Salary column

WITH CleanedJobSalaries AS (
	SELECT *,
		LTRIM(RTRIM(REPLACE(REPLACE(REPLACE(Salary_Estimate, ' (Glassdoor est.)', ''),'Employer Provided Salary:', ''), ' Per Hour', ''))) as Cleaned_Salaries,
		CASE WHEN Salary_Estimate LIKE '%Per Hour%' THEN 1 ELSE 0 END AS Is_Hourly
	FROM DS_Jobs
	WHERE Job_Title <> '-1' AND Salary_Estimate <> '-1'
),

StateMap(FullName, Abbreviation) AS (
    SELECT * FROM (VALUES 
        ('Alabama','AL'),('Alaska','AK'),('Arizona','AZ'),('Arkansas','AR'),('California','CA'),
        ('Colorado','CO'),('Connecticut','CT'),('Delaware','DE'),('Florida','FL'),('Georgia','GA'),
        ('Hawaii','HI'),('Idaho','ID'),('Illinois','IL'),('Indiana','IN'),('Iowa','IA'),
        ('Kansas','KS'),('Kentucky','KY'),('Louisiana','LA'),('Maine','ME'),('Maryland','MD'),
        ('Massachusetts','MA'),('Michigan','MI'),('Minnesota','MN'),('Mississippi','MS'),('Missouri','MO'),
        ('Montana','MT'),('Nebraska','NE'),('Nevada','NV'),('New Hampshire','NH'),('New Jersey','NJ'),
        ('New Mexico','NM'),('New York','NY'),('North Carolina','NC'),('North Dakota','ND'),('Ohio','OH'),
        ('Oklahoma','OK'),('Oregon','OR'),('Pennsylvania','PA'),('Rhode Island','RI'),('South Carolina','SC'),
        ('South Dakota','SD'),('Tennessee','TN'),('Texas','TX'),('Utah','UT'),('Vermont','VT'),
        ('Virginia','VA'),('Washington','WA'),('West Virginia','WV'),('Wisconsin','WI'),('Wyoming','WY')
    ) AS St(F, A)
),

--Find the points where the split is between minimum and maximum salary
MinMaxSplitPoint AS(
	SELECT *,
		CHARINDEX('-', Cleaned_Salaries) AS SplitPosition,
		--Also separates the ratings from the names that incidentally include them for future operating
		CHARINDEX(CHAR(10), Company_Name) AS NewlinePosition
	FROM CleanedJobSalaries
),

--Separate the salaries into min and max salaries into separate strings for further casting

MinMaxSeparated AS (
	SELECT Job_Title, Job_Description, Rating, Location, Company_Name, Is_Hourly, NewlinePosition,

		CASE
			WHEN SplitPosition > 0 THEN (SUBSTRING(Cleaned_Salaries, 1, SplitPosition - 1))
			ELSE Cleaned_Salaries
		END AS Min_Sal_Raw,

		CASE
			WHEN SplitPosition > 0 THEN SUBSTRING(Cleaned_Salaries, SplitPosition + 1, LEN(Cleaned_Salaries))
			ELSE Cleaned_Salaries
		END AS Max_Sal_Raw

	FROM MinMaxSplitPoint
),

SanitizedSalaries AS (
	SELECT *,
		LTRIM(RTRIM(REPLACE(REPLACE(Min_Sal_Raw, '$', ''), 'K', ''))) AS Min_Sal_Clean,
		LTRIM(RTRIM(REPLACE(REPLACE(Max_Sal_Raw, '$', ''), 'K', ''))) AS Max_Sal_Clean
	FROM MinMaxSeparated
)



SELECT Job_Title, 

	--Round salaries to a single precision point, setting them NULL if they are -1 to prevent mixing with valid numbers
	NULLIF(ROUND(Rating, 1), -1) AS Rating_Rounded, 

	--Uses the name rating in previous CTE to parse company names depending on if their ratings are mixed with their names
	CASE
		WHEN NewlinePosition > 0 THEN SUBSTRING(Company_Name, 1, NewlinePosition - 1)
		ELSE Company_Name
	END AS Company_Name_Cleaned,
	
	--Parses city from location, unless the job is remote, then that is also here; checks if the location is a standalone state, if it isn't then it defaults to the given name
	CASE
		WHEN Location LIKE '%,%' THEN LTRIM(RTRIM(SUBSTRING(Location, 1, CHARINDEX(',', Location) -1)))
		WHEN Location = 'Remote' THEN 'Remote'
		WHEN Location IN ('United States', 'US') THEN 'Unspecified'
		WHEN Location NOT IN (SELECT FullName FROM StateMap) AND Location NOT IN (SELECT Abbreviation FROM StateMap) THEN Location
		ELSE 'Unspecified'
	END AS City,

	--Parses state from location, unless the job is remote, then that is also here; checks if the location is a standalone state and assigns it to its repective abbreviation if not already abbreviated
	CASE
		WHEN Location LIKE '%,%' THEN LTRIM(RTRIM(SUBSTRING(Location, CHARINDEX(',', Location) +1, LEN(Location))))
		WHEN Location = 'Remote' THEN 'Remote'
		WHEN Location IN ('United States', 'US') THEN 'Unspecified'
		WHEN Location IN (SELECT FullName FROM StateMap) OR Location IN (SELECT Abbreviation FROM StateMap) THEN COALESCE((SELECT Abbreviation FROM StateMap WHERE Location = FullName), LOCATION)
		ELSE 'Unspecified'
	END AS State,

	--Converts to decimal and converts hourly to yearly for minimum salaries
	CASE 
		WHEN Is_Hourly = 1 THEN (TRY_CAST(Min_Sal_Clean AS DECIMAL(10,2)) * 2080)
		ELSE TRY_CAST(Min_Sal_Clean AS DECIMAL(10,2)) * 1000
	END AS Min_Salary,

	--Converts to decimal and converts hourly to yearly for maximum salaries
	CASE 
		WHEN Is_Hourly = 1 THEN (TRY_CAST(Max_Sal_Clean AS DECIMAL(10,2)) * 2080)
		ELSE TRY_CAST(Max_Sal_Clean AS DECIMAL(10,2)) * 1000
	END AS Max_Salary,

	CASE
		WHEN LOWER(Job_Description) LIKE '%sql%' THEN 1
		ELSE 0
	END AS ReqSQL,

	CASE
		WHEN LOWER(Job_Description) LIKE '%python%' THEN 1
		ELSE 0
	END AS ReqPython,

	CASE
		WHEN LOWER(Job_Description) LIKE '%tableau%' THEN 1
		ELSE 0
	END AS ReqTableau,

	CASE
		WHEN LOWER(Job_Description) LIKE '%powerbi%' OR LOWER(Job_Description) LIKE '%power bi%' THEN 1
		ELSE 0
	END AS ReqPowerBI,

	CASE
		WHEN Location = 'Remote' THEN 0
		ELSE 1
	END AS OnSite

INTO Cleaned_Listings
From SanitizedSalaries
WHERE Company_Name <> '-1';

--Look at all the cleaned data and sort it by state, city and minimum salary for readablity

SELECT *
From Cleaned_Listings
ORDER BY State, City, Min_Salary DESC;

--Find the average minimum and maximum salary for remote workers against onsite

SELECT
	CASE
		WHEN OnSite = 1 THEN 'On Site'
		ELSE 'Remote'
	END AS Onsite,
	AVG(Max_Salary) AS AverageMaximumSalary,
	AVG(Min_Salary) AS AverageMinimumSalary
FROM Cleaned_Listings
GROUP BY OnSite
ORDER BY AverageMaximumSalary DESC, AverageMinimumSalary DESC;

--Find the highest paying city in which state for data science

SELECT State, City,
	AVG(Max_Salary) AS AverageMaximumSalary,
	AVG(Min_Salary) AS AverageMinimumSalary
FROM Cleaned_Listings
GROUP BY State, City
ORDER BY AverageMaximumSalary DESC, AverageMinimumSalary DESC;

--Find the biggest spread in minimum vs maximum salary by city

SELECT State, City,
	AVG(Max_Salary - Min_Salary) AS AverageSalarySpread
FROM Cleaned_Listings
GROUP BY State, City
ORDER BY AverageSalarySpread DESC;

--Find the average minimum salary and maximum salary for jobs requiring SQL, Python, Tableau, and PowerBI

SELECT
    CASE 
        WHEN ReqSQL = 1 AND ReqPython = 1 AND (ReqTableau = 1 OR ReqPowerBI = 1) THEN 'Full-Stack Analyst'
        WHEN ReqSQL = 1 AND ReqPython = 1 AND ReqTableau = 0 AND ReqPowerBI = 0 THEN 'Data Engineer / Backend Analyst'
        WHEN ReqSQL = 1 AND ReqPython = 0 AND (ReqTableau = 1 OR ReqPowerBI = 1) THEN 'Traditional BI Analyst'
        WHEN ReqSQL = 0 AND ReqPython = 1 AND ReqTableau = 0 AND ReqPowerBI = 0 THEN 'Python Specialist / Data Scientist'
        WHEN ReqSQL = 0 AND ReqPython = 0 AND ReqTableau = 0 AND ReqPowerBI = 0 THEN 'Baseline / Non-Technical'
        ELSE 'Other Specialized Stack'
    END AS Data_Role_Profile,
	COUNT(*) AS Job_Count,
	AVG(Max_Salary) AS AverageMaximumSalary,
	AVG(Min_Salary) AS AverageMinimumSalary
FROM Cleaned_Listings
GROUP BY
	CASE 
        WHEN ReqSQL = 1 AND ReqPython = 1 AND (ReqTableau = 1 OR ReqPowerBI = 1) THEN 'Full-Stack Analyst'
        WHEN ReqSQL = 1 AND ReqPython = 1 AND ReqTableau = 0 AND ReqPowerBI = 0 THEN 'Data Engineer / Backend Analyst'
        WHEN ReqSQL = 1 AND ReqPython = 0 AND (ReqTableau = 1 OR ReqPowerBI = 1) THEN 'Traditional BI Analyst'
        WHEN ReqSQL = 0 AND ReqPython = 1 AND ReqTableau = 0 AND ReqPowerBI = 0 THEN 'Python Specialist / Data Scientist'
        WHEN ReqSQL = 0 AND ReqPython = 0 AND ReqTableau = 0 AND ReqPowerBI = 0 THEN 'Baseline / Non-Technical'
        ELSE 'Other Specialized Stack'
    END
ORDER BY AverageMinimumSalary DESC;

--Find the average spread in salaries by skillset

SELECT
    Data_Role_Profile,
	COUNT(*) AS Job_Count,
	AVG(Max_Salary - Min_Salary) AS AverageSalarySpread
FROM (
	SELECT *,
		CASE 
			WHEN ReqSQL = 1 AND ReqPython = 1 AND (ReqTableau = 1 OR ReqPowerBI = 1) THEN 'Full-Stack Analyst'
			WHEN ReqSQL = 1 AND ReqPython = 1 AND ReqTableau = 0 AND ReqPowerBI = 0 THEN 'Data Engineer / Backend Analyst'
			WHEN ReqSQL = 1 AND ReqPython = 0 AND (ReqTableau = 1 OR ReqPowerBI = 1) THEN 'Traditional BI Analyst'
			WHEN ReqSQL = 0 AND ReqPython = 1 AND ReqTableau = 0 AND ReqPowerBI = 0 THEN 'Python Specialist / Data Scientist'
			WHEN ReqSQL = 0 AND ReqPython = 0 AND ReqTableau = 0 AND ReqPowerBI = 0 THEN 'Baseline / Non-Technical'
			ELSE 'Other Specialized Stack'
		END AS Data_Role_Profile
	FROM Cleaned_Listings
) AS ProfiledJobs
GROUP BY Data_Role_Profile
ORDER BY AverageSalarySpread ASC;

--Find the average salary by company rating

SELECT Rating_Rounded, AVG(Min_Salary) AS AvgMinSalary, AVG(Max_Salary) AS AvgMaxSalary
FROM Cleaned_Listings
GROUP BY Rating_Rounded
ORDER BY Rating_Rounded DESC;