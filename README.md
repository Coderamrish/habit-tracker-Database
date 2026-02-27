# Habit Tracker Database

## Overview
The Habit Tracker Database is designed to help users systematically track and build their habits over time. It provides a structured way to record, analyze, and visualize habit performance.

## Features
- **User Authentication**: Secure login and registration for personal habit tracking.
- **Habit Management**: Create, update, and delete habits.
- **Tracking**: Log daily progress and visualize habit streaks.
- **Reporting**: Generate reports based on habit performance and consistency.

## Database Schema
The database is comprised of several key tables:

### 1. Users Table
- **user_id** (Primary Key): Unique identifier for each user.
- **username**: User's chosen username.
- **password_hash**: Hashed password for user authentication.

### 2. Habits Table
- **habit_id** (Primary Key): Unique identifier for each habit.
- **user_id** (Foreign Key): Reference to the user who owns the habit.
- **name**: Name of the habit.
- **description**: Detailed description of the habit.
- **frequency**: How often the habit should be tracked (daily, weekly, etc.).

### 3. Habit_Logs Table
- **log_id** (Primary Key): Unique identifier for each log entry.
- **habit_id** (Foreign Key): Reference to the habit being tracked.
- **date**: Date of the log entry.
- **status**: Completion status of the habit (completed, skipped, etc.).

## Setup Instructions
1. **Clone the Repository**:
   ```sh
   git clone https://github.com/Coderamrish/habit-tracker-Database.git
   cd habit-tracker-Database
   ```
2. **Install Dependencies**:
   Install the required packages, typically using a package manager like npm or pip, depending on your tech stack.
3. **Set Up the Database**:
   - Configure your database connection in the `.env` file.
   - Run the database migrations to create the necessary tables.
     ```sh
     # For example, using a Node.js setup
     npm run migrate
     ```
4. **Run the Application**:
   Start the application server:
   ```sh
   # Example command
   npm start
   ```
5. **Access the Application**:
   Open your web browser and go to `http://localhost:3000` or the configured URL.

By following these steps, users can successfully set up and utilize the Habit Tracker Database to monitor and improve their habit formation.