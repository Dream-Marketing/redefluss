#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Führt den Block aus und liefert eine dabei geworfene Objective-C-Exception zurück, statt den
/// Prozess abstürzen zu lassen. Swift kann NSException nicht fangen – AVFoundation wirft sie aber,
/// z. B. wenn beim Start der Aufnahme kein Eingabegerät da ist oder sein Format gerade wechselt.
NSException * _Nullable RDFCatchException(void (NS_NOESCAPE ^block)(void));

NS_ASSUME_NONNULL_END
