
    SELECT
        procedure.person_id,
        procedure.procedure_concept_id,
        p_standard_concept.concept_name as standard_concept_name,
        p_standard_concept.concept_code as standard_concept_code,
        p_standard_concept.vocabulary_id as standard_vocabulary,
        procedure.procedure_datetime,
        procedure.procedure_type_concept_id,
        p_type.concept_name as procedure_type_concept_name,
        procedure.modifier_concept_id,
        p_modifier.concept_name as modifier_concept_name,
        procedure.quantity,
        procedure.visit_occurrence_id,
        p_visit.concept_name as visit_occurrence_concept_name,
        procedure.procedure_source_value,
        procedure.procedure_source_concept_id,
        p_source_concept.concept_name as source_concept_name,
        p_source_concept.concept_code as source_concept_code,
        p_source_concept.vocabulary_id as source_vocabulary,
        procedure.modifier_source_value 
    FROM
        ( SELECT
            * 
        FROM
            `procedure_occurrence` procedure 
        WHERE
            (
                procedure_source_concept_id IN (
                    SELECT
                        DISTINCT c.concept_id 
                    FROM
                        `cb_criteria` c 
                    JOIN
                        (
                            SELECT
                                CAST(cr.id as string) AS id       
                            FROM
                                `cb_criteria` cr       
                            WHERE
                                concept_id IN (
                                    2107216, 2107217, 2107218, 2107219, 2107220, 2107221, 2107222, 2107223, 2107224, 2107226, 2107227, 2107228, 2107231, 2107242, 2107243, 2107244, 2107250, 2313796, 2313801, 2313802, 2313803, 2313804, 2313810, 2313811, 43527908, 43527909, 43527994, 43527995, 43527996, 43527997, 43527998, 43527999, 43528000, 43528001, 43528002, 43528003, 43528004
                                )       
                                AND full_text LIKE '%_rank1]%'      
                        ) a 
                            ON (
                                c.path LIKE CONCAT('%.',
                            a.id,
                            '.%') 
                            OR c.path LIKE CONCAT('%.',
                            a.id) 
                            OR c.path LIKE CONCAT(a.id,
                            '.%') 
                            OR c.path = a.id) 
                        WHERE
                            is_standard = 0 
                            AND is_selectable = 1
                        )
                )  
                AND (
                    procedure.PERSON_ID IN (
                        SELECT
                            distinct person_id  
                        FROM
                            `cb_search_person` cb_search_person  
                        WHERE
                            cb_search_person.person_id IN (
                                SELECT
                                    person_id 
                                FROM
                                    `cb_search_person` p 
                                WHERE
                                    has_whole_genome_variant = 1 
                            ) 
                        )
                )
            ) procedure 
        LEFT JOIN
            `concept` p_standard_concept 
                ON procedure.procedure_concept_id = p_standard_concept.concept_id 
        LEFT JOIN
            `concept` p_type 
                ON procedure.procedure_type_concept_id = p_type.concept_id 
        LEFT JOIN
            `concept` p_modifier 
                ON procedure.modifier_concept_id = p_modifier.concept_id 
        LEFT JOIN
            `visit_occurrence` v 
                ON procedure.visit_occurrence_id = v.visit_occurrence_id 
        LEFT JOIN
            `concept` p_visit 
                ON v.visit_concept_id = p_visit.concept_id 
        LEFT JOIN
            `concept` p_source_concept 
                ON procedure.procedure_source_concept_id = p_source_concept.concept_id