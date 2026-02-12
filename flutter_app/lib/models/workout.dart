class Workout {
  final String name;
  final double goal;
  final String units;
  final bool atPark;

  Workout({
    required this.name,
    required this.goal,
    required this.units,
    required this.atPark,
  });

  factory Workout.fromJson(Map<String, dynamic> json) {
    return Workout(
      name: json['name'],
      goal: json['goal'].toDouble(),
      units: json['units'],
      atPark: json['at_park'],
    );
  }
}

class WorkoutScheduleItem {
  final String date;
  final String workout;
  final double? score;
  final String units;
  final bool atPark;
  final double goal;

  WorkoutScheduleItem({
    required this.date,
    required this.workout,
    this.score,
    required this.units,
    required this.atPark,
    required this.goal,
  });

  factory WorkoutScheduleItem.fromJson(Map<String, dynamic> json) {
    return WorkoutScheduleItem(
      date: json['date'],
      workout: json['workout'],
      score: json['score']?.toDouble(),
      units: json['units'],
      atPark: json['at_park'],
      goal: json['goal'].toDouble(),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'date': date,
      'workout': workout,
      'score': score,
      'units': units,
      'at_park': atPark,
      'goal': goal,
    };
  }

  bool get isCompleted => score != null;
  
  double get progressPercentage {
    if (score == null) return 0.0;
    return (score! / goal * 100).clamp(0.0, 100.0);
  }
}