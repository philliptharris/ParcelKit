//
//  DBRecord+ParcelKit.m
//  ParcelKit
//
//  Copyright (c) 2013 Overcommitted, LLC. All rights reserved.
//
//  Permission is hereby granted, free of charge, to any person obtaining a copy
//  of this software and associated documentation files (the "Software"), to deal
//  in the Software without restriction, including without limitation the rights
//  to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
//  copies of the Software, and to permit persons to whom the Software is
//  furnished to do so, subject to the following conditions:
//
//  The above copyright notice and this permission notice shall be included in
//  all copies or substantial portions of the Software.
//
//  THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
//  IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
//  FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
//  AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
//  LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
//  OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
//  THE SOFTWARE.
//

#import "DBRecord+ParcelKit.h"

@implementation DBRecord (ParcelKit)

- (void)pk_setFieldsWithManagedObject:(NSManagedObject *)managedObject syncAttributeName:(NSString *)syncAttributeName {
    
    __weak typeof(self) weakSelf = self;
    
    NSDictionary *propertiesByName = [[managedObject entity] propertiesByName];
    
    NSDictionary *values = [managedObject dictionaryWithValuesForKeys:[propertiesByName allKeys]];
    
    [values enumerateKeysAndObjectsUsingBlock:^(NSString *nameOfPropertyInCoreData, id valueInCoreData, BOOL *stop) {
        
        typeof(self) strongSelf = weakSelf;
        
        if (!strongSelf) {
            return;
        }
        
        if ([nameOfPropertyInCoreData isEqualToString:syncAttributeName]) {
            return;
        }
        
        if (valueInCoreData && valueInCoreData != [NSNull null]) {
            
            NSPropertyDescription *propertyDescription = [propertiesByName objectForKey:nameOfPropertyInCoreData];
            if ([propertyDescription isTransient]) {
                return;
            }
            
            //
            // ATTRIBUTE
            //
            if ([propertyDescription isKindOfClass:[NSAttributeDescription class]]) {
                
                id previousValue = [strongSelf objectForKey:nameOfPropertyInCoreData];
                if (!previousValue || [previousValue compare:valueInCoreData] != NSOrderedSame) {
                    [strongSelf setObject:valueInCoreData forKey:nameOfPropertyInCoreData];
                }
            }
            
            //
            // RELATIONSHIP
            //
            else if ([propertyDescription isKindOfClass:[NSRelationshipDescription class]]) {
                
                //
                // TO-MANY RELATIONSHIP
                //
                if ([(NSRelationshipDescription *)propertyDescription isToMany]) {
                    
                    DBList *fieldList = [strongSelf getOrCreateList:nameOfPropertyInCoreData];
                    NSSet *previousIdentifiers = [[NSMutableSet alloc] initWithArray:[fieldList values]];
                    NSSet *currentIdentifiers = [[NSSet alloc] initWithArray:[[valueInCoreData allObjects] valueForKey:syncAttributeName]];
                    
                    NSMutableSet *deletedIdentifiers = [[NSMutableSet alloc] initWithSet:previousIdentifiers];
                    [deletedIdentifiers minusSet:currentIdentifiers];
                    for (NSString *recordId in deletedIdentifiers) {
                        NSInteger index = [[fieldList values] indexOfObject:recordId];
                        if (index != NSNotFound) {
                            [fieldList removeObjectAtIndex:index];
                        }
                    }
                    
                    NSMutableSet *insertedIdentifiers = [[NSMutableSet alloc] initWithSet:currentIdentifiers];
                    [insertedIdentifiers minusSet:previousIdentifiers];
                    for (NSString *recordId in insertedIdentifiers) {
                        if (![[fieldList values] containsObject:recordId]) {
                            [fieldList addObject:recordId];
                        }
                    }
                }
                
                //
                // TO-ONE RELATIONSHIP
                //
                else {
                    [strongSelf setObject:[valueInCoreData valueForKey:syncAttributeName] forKey:nameOfPropertyInCoreData];
                }
            }
        }
        else {
            
            NSArray *fieldNames = [[self fields] allKeys];
            
            if ([fieldNames containsObject:nameOfPropertyInCoreData]) {
                [strongSelf removeObjectForKey:nameOfPropertyInCoreData];
            }
        }
    }];
}
@end
